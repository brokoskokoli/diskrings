import Foundation

// MARK: Bausteine (austauschbar für Tests)

/// Ergebnis beim Auflösen eines Bookmarks: aktueller Pfad (ein verschobener
/// Ordner wird gefunden) und ob das Bookmark erneuert werden sollte.
public struct ResolvedBookmark: Sendable, Equatable {
    public var path: String
    public var isStale: Bool

    public init(path: String, isStale: Bool) {
        self.path = path
        self.isStale = isStale
    }
}

/// Security-Scoped Bookmarks (App-Sandbox). `SystemBookmarks` nutzt die
/// echten Bookmarks von Foundation; Tests schieben einen Ersatz unter.
public protocol SecurityScopedBookmarks: AnyObject {
    /// Bookmark für einen Ordner, auf den die App gerade Zugriff hat
    /// (Öffnen-Dialog, Drag & Drop oder aufgelöstes Bookmark).
    func bookmark(forPath path: String) throws -> Data
    func resolve(_ data: Data) throws -> ResolvedBookmark
    /// `startAccessingSecurityScopedResource`; `false`, wenn nichts zu
    /// starten war (dann auch kein `stopAccessing`).
    func startAccessing(path: String) -> Bool
    func stopAccessing(path: String)
}

/// Ablage der Bookmarks zwischen zwei Starts.
public protocol GrantPersistence: AnyObject {
    func load() -> [Data]
    func save(_ bookmarks: [Data])
}

/// Bookmarks in den UserDefaults der App (in der Sandbox im Container).
public final class UserDefaultsGrantPersistence: GrantPersistence {
    public static let defaultKey = "folderAccessBookmarks"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsGrantPersistence.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [Data] { defaults.array(forKey: key) as? [Data] ?? [] }
    public func save(_ bookmarks: [Data]) { defaults.set(bookmarks, forKey: key) }
}

/// Bookmarks nur im Speicher (Vorschaubilder).
public final class InMemoryGrantPersistence: GrantPersistence {
    private var stored: [Data] = []
    public init() {}
    public func load() -> [Data] { stored }
    public func save(_ bookmarks: [Data]) { stored = bookmarks }
}

/// App-bezogene Security-Scoped Bookmarks über Foundation
/// (`com.apple.security.files.bookmarks.app-scope`). Merkt sich die
/// aufgelösten bzw. übernommenen URLs: Nur auf ihnen wirkt
/// `startAccessingSecurityScopedResource`.
public final class SystemBookmarks: SecurityScopedBookmarks {
    private var urls: [String: URL] = [:]

    public init() {}

    /// Übernimmt eine URL mit Zugriffsrecht (aus dem Öffnen-Dialog oder
    /// Drag & Drop), damit das Bookmark aus genau dieser URL entsteht.
    public func adopt(_ url: URL) {
        urls[FolderAccessStore.standardized(url.path) ?? url.path] = url
    }

    public func bookmark(forPath path: String) throws -> Data {
        let url = urls[path] ?? URL(fileURLWithPath: path, isDirectory: true)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        let path = FolderAccessStore.standardized(url.path) ?? url.path
        urls[path] = url
        return ResolvedBookmark(path: path, isStale: stale)
    }

    public func startAccessing(path: String) -> Bool {
        (urls[path] ?? URL(fileURLWithPath: path, isDirectory: true)).startAccessingSecurityScopedResource()
    }

    public func stopAccessing(path: String) {
        (urls[path] ?? URL(fileURLWithPath: path, isDirectory: true)).stopAccessingSecurityScopedResource()
    }
}

// MARK: Freigaben

/// Ordnerfreigaben der App-Store-Variante (SPEC 11.2): In der Sandbox liest
/// DiskRings nur Ordner und Volumes, die der Nutzer im Öffnen-Dialog oder per
/// Drag & Drop gewählt hat. Die Freigaben werden als app-bezogene
/// Security-Scoped Bookmarks gespeichert, beim Start aufgelöst (veraltete
/// erneuert, unauflösbare verworfen) und lassen sich widerrufen.
///
/// Ein angefragter Pfad ist gedeckt, wenn er eine Freigabe ist oder darunter
/// liegt (an einer Komponentengrenze, ohne Groß-/Kleinschreibung und
/// Unicode-Normalform). Zugriffe laufen über gezählte Leases: Der erste
/// startet `startAccessingSecurityScopedResource` auf der Freigabe, der
/// letzte beendet ihn.
@MainActor
public final class FolderAccessStore {
    public struct Grant: Sendable, Equatable {
        /// Pfad der Freigabe (standardisiert, ohne Schrägstrich am Ende).
        public var path: String
        /// Bleibt über einen Neustart erhalten (Bookmark gespeichert); sonst
        /// gilt die Freigabe nur bis zum Beenden der App.
        public var isPersistent: Bool { bookmark != nil }
        var bookmark: Data?
        var key: String
    }

    public enum GrantResult: Sendable, Equatable {
        case granted(persisted: Bool)
        /// Schon durch diese Freigabe gedeckt.
        case alreadyCovered(by: String)
        /// Kein absoluter Pfad.
        case invalid
    }

    public struct LoadReport: Sendable, Equatable {
        public var restored: Int
        public var refreshed: Int
        public var dropped: Int

        public init(restored: Int, refreshed: Int, dropped: Int) {
            self.restored = restored
            self.refreshed = refreshed
            self.dropped = dropped
        }
    }

    /// Ein laufender Zugriff; mit `endAccess` beenden.
    public struct Lease: Sendable, Hashable {
        let id: UInt64
        let key: String
        /// Freigabe, unter der zugegriffen wird.
        public let grantPath: String
    }

    public private(set) var grants: [Grant] = []

    private let backend: any SecurityScopedBookmarks
    private let persistence: any GrantPersistence
    private var nextLeaseID: UInt64 = 1
    private var activeLeases: Set<UInt64> = []
    private var accessCounts: [String: Int] = [:]
    private var startedKeys: Set<String> = []

    public init(backend: any SecurityScopedBookmarks, persistence: any GrantPersistence) {
        self.backend = backend
        self.persistence = persistence
    }

    // MARK: Laden

    /// Liest die gespeicherten Bookmarks: auflösen, veraltete erneuern (mit
    /// Zugriff während der Erneuerung), unauflösbare verwerfen, Doppelte und
    /// schon gedeckte zusammenfassen. Speichert nur bei einer Änderung.
    @discardableResult
    public func load() -> LoadReport {
        var loaded: [Grant] = []
        var refreshed = 0, dropped = 0
        var changed = false
        for data in persistence.load() {
            guard let r = try? backend.resolve(data), let path = Self.standardized(r.path), let key = Self.key(path)
            else {
                dropped += 1
                changed = true
                continue
            }
            var bookmark = data
            if r.isStale {
                let started = backend.startAccessing(path: path)
                if let fresh = try? backend.bookmark(forPath: path) {
                    bookmark = fresh
                    refreshed += 1
                    changed = true
                }
                if started { backend.stopAccessing(path: path) }
            }
            loaded.append(Grant(path: path, bookmark: bookmark, key: key))
        }
        // Freigaben dieser Sitzung (ohne Bookmark) bleiben erhalten.
        loaded += grants.filter { !$0.isPersistent }
        let merged = Self.withoutCovered(loaded)
        if merged.count != loaded.count { changed = true }
        grants = merged.sorted { $0.path < $1.path }
        if changed { save() }
        return LoadReport(restored: grants.count, refreshed: refreshed, dropped: dropped)
    }

    /// Ohne Freigaben, die eine andere schon deckt (die kürzere gewinnt).
    private static func withoutCovered(_ list: [Grant]) -> [Grant] {
        var out: [Grant] = []
        let ordered = list.enumerated().sorted { ($0.element.key.count, $0.offset) < ($1.element.key.count, $1.offset) }
        for (_, g) in ordered where !out.contains(where: { isWithin(g.key, $0.key) }) {
            out.append(g)
        }
        return out
    }

    // MARK: Freigeben, prüfen, widerrufen

    /// Nimmt einen Ordner auf, auf den die App gerade Zugriff hat (Öffnen-
    /// Dialog, Drag & Drop). Freigaben darunter werden durch ihn ersetzt.
    @discardableResult
    public func grant(path: String) -> GrantResult {
        guard let display = Self.standardized(path), let key = Self.key(display) else { return .invalid }
        if let existing = deepestGrant(forKey: key) { return .alreadyCovered(by: existing.path) }
        let bookmark = try? backend.bookmark(forPath: display)
        grants.removeAll { Self.isWithin($0.key, key) }
        grants.append(Grant(path: display, bookmark: bookmark, key: key))
        grants.sort { $0.path < $1.path }
        save()
        return .granted(persisted: bookmark != nil)
    }

    /// Ist der Pfad durch eine Freigabe gedeckt?
    public func covers(_ path: String) -> Bool { grantedAncestor(for: path) != nil }

    /// Die tiefste Freigabe, die den Pfad deckt.
    public func grantedAncestor(for path: String) -> String? {
        guard let key = Self.key(path) else { return nil }
        return deepestGrant(forKey: key)?.path
    }

    private func deepestGrant(forKey key: String) -> Grant? {
        grants.filter { Self.isWithin(key, $0.key) }.max { $0.key.count < $1.key.count }
    }

    /// Entfernt genau diese Freigabe (nicht ihre Vorfahren) und beendet
    /// einen laufenden Zugriff darauf. `false`, wenn es sie nicht gibt.
    @discardableResult
    public func revoke(path: String) -> Bool {
        guard let key = Self.key(path), let i = grants.firstIndex(where: { $0.key == key }) else { return false }
        let g = grants.remove(at: i)
        if startedKeys.remove(key) != nil { backend.stopAccessing(path: g.path) }
        accessCounts[key] = nil
        save()
        return true
    }

    private func save() {
        persistence.save(grants.compactMap(\.bookmark))
    }

    // MARK: Zugriff

    /// Beginnt einen Zugriff auf einen gedeckten Pfad; `nil` ohne Freigabe.
    public func beginAccess(for path: String) -> Lease? {
        guard let key = Self.key(path), let g = deepestGrant(forKey: key) else { return nil }
        let count = accessCounts[g.key] ?? 0
        if count == 0, backend.startAccessing(path: g.path) { startedKeys.insert(g.key) }
        accessCounts[g.key] = count + 1
        let lease = Lease(id: nextLeaseID, key: g.key, grantPath: g.path)
        nextLeaseID += 1
        activeLeases.insert(lease.id)
        return lease
    }

    /// Beendet einen Zugriff; ein zweites Ende desselben Leases zählt nicht.
    public func endAccess(_ lease: Lease) {
        guard activeLeases.remove(lease.id) != nil, let count = accessCounts[lease.key] else { return }
        if count <= 1 {
            accessCounts[lease.key] = nil
            if startedKeys.remove(lease.key) != nil { backend.stopAccessing(path: lease.grantPath) }
        } else {
            accessCounts[lease.key] = count - 1
        }
    }

    /// Anzahl der Freigaben mit laufendem Zugriff.
    public var activeAccessCount: Int { accessCounts.count }

    // MARK: Pfade

    /// Absoluter Pfad ohne `.`/`..`, doppelte und abschließende Schrägstriche;
    /// `nil` bei einem relativen Pfad.
    nonisolated public static func standardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Vergleichsschlüssel: standardisiert, Unicode-NFC, klein geschrieben.
    /// Bewusst ohne die Firmlink-Abbildung der Schutzliste: Eine Freigabe von
    /// `/System/Volumes/Data` deckt nicht `/System` (lieber einmal mehr fragen).
    nonisolated static func key(_ path: String) -> String? {
        standardized(path).map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    nonisolated static func isWithin(_ path: String, _ base: String) -> Bool {
        base == "/" || path == base || path.hasPrefix(base + "/")
    }
}
