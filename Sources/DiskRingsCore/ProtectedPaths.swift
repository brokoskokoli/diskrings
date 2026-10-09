import Darwin
import Foundation

/// Schutzliste für das Löschen (SPEC 3.6). Für diese Pfade gibt es keinen
/// Papierkorb, weder im Menü noch per Tastenkürzel, und auch `TrashService`
/// lehnt sie ab:
///
/// - `/System`, `/usr` (außer `/usr/local`), `/bin`, `/sbin`,
///   `/private/var/db`, `/Library/Apple` samt Inhalt
/// - jede Volume-Wurzel (auch `/`)
/// - das Home-Verzeichnis als Ganzes und `~/Library` als Ganzes
/// - die laufende App samt Inhalt
/// - jeder Ordner, der einen der genannten Bereiche **enthält** (z. B.
///   `/Users`, `/Library`, `/Applications` mit der laufenden App): Mit ihm
///   würde der geschützte Bereich ebenfalls verschoben.
///
/// Pfade werden vor dem Vergleich normalisiert (`.`/`..`, doppelte und
/// abschließende Schrägstriche, `/var` → `/private/var`, Firmlink-Pfade unter
/// `/System/Volumes/Data` → `/…`) und ohne Rücksicht auf Groß-/Kleinschreibung
/// und Unicode-Normalform verglichen. Das schützt im Zweifel mehr, nie weniger.
public struct ProtectedPaths: Sendable, Equatable {
    /// Systembereiche samt Inhalt.
    public static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple"]
    /// Ausnahmen innerhalb der Systembereiche.
    public static let systemExceptions = ["/usr/local"]

    /// Grund, warum ein Pfad geschützt ist.
    public indirect enum Reason: Sendable, Equatable {
        /// Systembereich (mit dem passenden Eintrag der Liste).
        case system(String)
        case volumeRoot
        case home
        case homeLibrary
        case runningApp
        /// Der Ordner enthält einen geschützten Bereich.
        case containsProtected(path: String, reason: Reason)

        /// Text für Tooltip und Fehlermeldung.
        public var message: String {
            switch self {
            case .system(let p): L("protected.system", p)
            case .volumeRoot: L("protected.volumeRoot")
            case .home: L("protected.home")
            case .homeLibrary: L("protected.homeLibrary")
            case .runningApp: L("protected.runningApp")
            case .containsProtected(let p, let r): L("protected.contains", p, r.message)
            }
        }
    }

    public var home: String
    public var appBundlePath: String?
    public var volumeRoots: [String]

    private let normHome: String
    private let normHomeLibrary: String
    private let normApp: String?
    private let normVolumes: Set<String>

    public init(home: String = NSHomeDirectory(), appBundlePath: String? = ProtectedPaths.runningAppBundlePath(),
                volumeRoots: [String] = ProtectedPaths.mountedVolumeRoots()) {
        self.home = home
        self.appBundlePath = appBundlePath
        self.volumeRoots = volumeRoots
        normHome = Self.normalize(home)
        normHomeLibrary = Self.normalize(home + "/Library")
        normApp = appBundlePath.map(Self.normalize)
        normVolumes = Set(volumeRoots.map(Self.normalize))
    }

    /// `nil`, wenn der Pfad in den Papierkorb darf.
    public func reason(for path: String) -> Reason? {
        let n = Self.normalize(path)
        if let r = directReason(n) { return r }
        // Enthält der Ordner einen geschützten Bereich?
        for (anchor, display, r) in anchors() where Self.isStrictDescendant(anchor, of: n) {
            return .containsProtected(path: display, reason: r)
        }
        return nil
    }

    public func isProtected(_ path: String) -> Bool { reason(for: path) != nil }

    private func directReason(_ n: String) -> Reason? {
        if n == "/" || normVolumes.contains(n) { return .volumeRoot }
        for p in Self.systemPrefixes where Self.isWithin(n, Self.key(p)) {
            if !Self.systemExceptions.contains(where: { Self.isWithin(n, Self.key($0)) }) { return .system(p) }
        }
        if let app = normApp, Self.isWithin(n, app) { return .runningApp }
        if n == normHome { return .home }
        if n == normHomeLibrary { return .homeLibrary }
        return nil
    }

    /// Geschützte Bereiche, deren Vorfahren ebenfalls geschützt sind.
    private func anchors() -> [(String, String, Reason)] {
        var out: [(String, String, Reason)] = Self.systemPrefixes.map { (Self.key($0), $0, .system($0)) }
        out.append((normHome, home, .home))
        if let app = normApp, let display = appBundlePath { out.append((app, display, .runningApp)) }
        for (v, display) in zip(volumeRoots.map(Self.normalize), volumeRoots) where v != "/" {
            out.append((v, display, .volumeRoot))
        }
        return out
    }

    // MARK: Normalisierung

    /// Normalisierter Vergleichsschlüssel eines absoluten Pfads.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(c)
        }
        var s = "/" + parts.joined(separator: "/")
        // Firmlinks: /System/Volumes/Data/Users/x ist dasselbe wie /Users/x.
        let data = "/System/Volumes/Data/"
        if s.lowercased().hasPrefix(data.lowercased()) {
            s = "/" + s.dropFirst(data.count)
        } else if s.lowercased() == "/system/volumes/data" {
            // Die Wurzel des Data-Volumes ist dasselbe wie „/“.
            s = "/"
        }
        // /var, /etc, /tmp sind Symlinks nach /private/….
        for link in ["/var", "/etc", "/tmp"] where s.lowercased() == link || s.lowercased().hasPrefix(link + "/") {
            s = "/private" + s
            break
        }
        return key(s)
    }

    /// Ohne Groß-/Kleinschreibung und Unicode-Normalform.
    static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    /// `path` ist `base` oder liegt darunter (an einer Komponentengrenze).
    static func isWithin(_ path: String, _ base: String) -> Bool {
        if base == "/" { return true }
        return path == base || path.hasPrefix(base + "/")
    }

    /// `path` liegt echt unterhalb von `ancestor`.
    static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        path != ancestor && isWithin(path, ancestor)
    }

    // MARK: Systemwerte

    /// Pfad des laufenden App-Bündels (nur, wenn es ein `.app` ist).
    public static func runningAppBundlePath() -> String? {
        let p = Bundle.main.bundlePath
        return p.hasSuffix(".app") ? p : nil
    }

    /// Einhängepunkte aller Volumes (`getmntinfo`).
    public static func mountedVolumeRoots() -> [String] {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return ["/"] }
        var out: [String] = []
        for i in 0 ..< Int(n) {
            var m = buf[i].f_mntonname
            let s = withUnsafeBytes(of: &m) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !s.isEmpty { out.append(s) }
        }
        return out
    }
}
