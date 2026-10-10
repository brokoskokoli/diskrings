@testable import DiskRingsCore
import Foundation
import Testing

/// Ersatz für die Security-Scoped Bookmarks: Ein „Bookmark“ ist der Pfad als
/// UTF-8, Fehler und veraltete Bookmarks lassen sich gezielt auslösen.
final class FakeBookmarks: SecurityScopedBookmarks {
    var failingPaths: Set<String> = []
    var stalePaths: Set<String> = []
    var unresolvablePaths: Set<String> = []
    /// Verschobene Ordner: Das Bookmark folgt ihnen an den neuen Ort.
    var moved: [String: String] = [:]
    var created: [String] = []
    var started: [String] = []
    var stopped: [String] = []
    var startResult = true

    struct Failure: Error {}

    func bookmark(forPath path: String) throws -> Data {
        if failingPaths.contains(path) { throw Failure() }
        created.append(path)
        return Data(path.utf8)
    }

    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let path = String(decoding: data, as: UTF8.self)
        if unresolvablePaths.contains(path) { throw Failure() }
        let current = moved[path] ?? path
        return ResolvedBookmark(path: current, isStale: stalePaths.contains(path) || moved[path] != nil)
    }

    func startAccessing(path: String) -> Bool {
        started.append(path)
        return startResult
    }

    func stopAccessing(path: String) { stopped.append(path) }
}

final class MemoryGrantPersistence: GrantPersistence {
    var stored: [Data] = []
    var saveCount = 0
    func load() -> [Data] { stored }
    func save(_ bookmarks: [Data]) {
        stored = bookmarks
        saveCount += 1
    }
}

@MainActor
@Suite("Ordnerfreigaben in der Sandbox (FolderAccessStore)")
struct FolderAccessStoreTests {
    let backend = FakeBookmarks()
    let persistence = MemoryGrantPersistence()

    func makeStore() -> FolderAccessStore {
        FolderAccessStore(backend: backend, persistence: persistence)
    }

    @Test("Freigabe deckt den Ordner und alles darunter, aber keine Geschwister mit gleichem Anfang")
    func coverage() {
        let s = makeStore()
        #expect(!s.covers("/Users/a/Documents"))
        _ = s.grant(path: "/Users/a/Documents")
        #expect(s.covers("/Users/a/Documents"))
        #expect(s.covers("/Users/a/Documents/x/y.txt"))
        #expect(s.covers("/Users/a/Documents/"))
        #expect(s.covers("/Users/a/Documents/x/../z"))
        #expect(s.covers("/users/A/documents/sub"))
        #expect(!s.covers("/Users/a/Documents2"))
        #expect(!s.covers("/Users/a/Doc"))
        #expect(!s.covers("/Users/a"))
        #expect(!s.covers("/Users/a/Documents/.."))
        #expect(!s.covers("relative/path"))
    }

    @Test("Unicode: NFC- und NFD-Schreibweise sind derselbe Ordner")
    func unicode() {
        let s = makeStore()
        _ = s.grant(path: "/Users/a/Fotos Gr\u{00FC}n")
        #expect(s.covers("/Users/a/Fotos Gru\u{0308}n/Bild.jpg"))
        #expect(s.grantedAncestor(for: "/Users/a/Fotos Gru\u{0308}n") == "/Users/a/Fotos Gr\u{00FC}n")
    }

    @Test("Volume-Wurzel „/“ deckt alles")
    func rootGrant() {
        let s = makeStore()
        _ = s.grant(path: "/")
        #expect(s.covers("/"))
        #expect(s.covers("/Volumes/USB/x"))
        #expect(s.grantedAncestor(for: "/Users") == "/")
    }

    @Test("Der tiefste passende Vorfahr wird gewählt")
    func deepestAncestor() {
        let s = makeStore()
        _ = s.grant(path: "/Volumes/A")
        _ = s.grant(path: "/Volumes/B/sub")
        #expect(s.grantedAncestor(for: "/Volumes/B/sub/deep") == "/Volumes/B/sub")
        #expect(s.grantedAncestor(for: "/Volumes/A/x") == "/Volumes/A")
        #expect(s.grantedAncestor(for: "/Volumes/B") == nil)
    }

    @Test("Freigabe eines Vorfahren ersetzt die Freigaben darunter; abgedeckte Pfade kommen nicht doppelt hinein")
    func ancestorReplacesDescendants() {
        let s = makeStore()
        _ = s.grant(path: "/Users/a/Documents")
        _ = s.grant(path: "/Users/a/Downloads")
        #expect(s.grants.map(\.path) == ["/Users/a/Documents", "/Users/a/Downloads"])
        _ = s.grant(path: "/Users/a")
        #expect(s.grants.map(\.path) == ["/Users/a"])
        let r = s.grant(path: "/Users/a/Music")
        #expect(r == .alreadyCovered(by: "/Users/a"))
        #expect(s.grants.map(\.path) == ["/Users/a"])
        #expect(persistence.stored == [Data("/Users/a".utf8)])
    }

    @Test("Freigaben bleiben über einen Neustart erhalten")
    func persistsAcrossLaunch() {
        let s = makeStore()
        #expect(s.grant(path: "/Volumes/Backup") == .granted(persisted: true))
        #expect(persistence.stored == [Data("/Volumes/Backup".utf8)])

        let relaunched = FolderAccessStore(backend: FakeBookmarks(), persistence: persistence)
        #expect(!relaunched.covers("/Volumes/Backup"))
        let report = relaunched.load()
        #expect(report == FolderAccessStore.LoadReport(restored: 1, refreshed: 0, dropped: 0))
        #expect(relaunched.covers("/Volumes/Backup/x"))
    }

    @Test("Veraltetes Bookmark wird beim Laden erneuert (mit Zugriff während der Erneuerung)")
    func staleRefresh() {
        persistence.stored = [Data("/Users/a/Old".utf8)]
        backend.stalePaths = ["/Users/a/Old"]
        let s = makeStore()
        let report = s.load()
        #expect(report == FolderAccessStore.LoadReport(restored: 1, refreshed: 1, dropped: 0))
        #expect(backend.created == ["/Users/a/Old"])
        #expect(backend.started == ["/Users/a/Old"])
        #expect(backend.stopped == ["/Users/a/Old"])
        #expect(persistence.saveCount == 1)
        #expect(s.covers("/Users/a/Old/x"))
    }

    @Test("Verschobener Ordner: Das Bookmark folgt, die Freigabe gilt für den neuen Pfad")
    func movedFolder() {
        persistence.stored = [Data("/Volumes/USB/Projekte".utf8)]
        backend.moved = ["/Volumes/USB/Projekte": "/Volumes/USB/Archiv/Projekte"]
        let s = makeStore()
        _ = s.load()
        #expect(s.covers("/Volumes/USB/Archiv/Projekte"))
        #expect(!s.covers("/Volumes/USB/Projekte"))
        #expect(persistence.stored == [Data("/Volumes/USB/Archiv/Projekte".utf8)])
    }

    @Test("Nicht auflösbares Bookmark (Ordner gelöscht, Volume weg) wird verworfen")
    func unresolvableDropped() {
        persistence.stored = [Data("/Volumes/Gone".utf8), Data("/Users/a/Keep".utf8)]
        backend.unresolvablePaths = ["/Volumes/Gone"]
        let s = makeStore()
        let report = s.load()
        #expect(report == FolderAccessStore.LoadReport(restored: 1, refreshed: 0, dropped: 1))
        #expect(s.grants.map(\.path) == ["/Users/a/Keep"])
        #expect(persistence.stored == [Data("/Users/a/Keep".utf8)])
    }

    @Test("Veraltetes Bookmark, das sich nicht erneuern lässt, bleibt für diese Sitzung nutzbar und gespeichert")
    func staleRefreshFails() {
        persistence.stored = [Data("/Users/a/Old".utf8)]
        backend.stalePaths = ["/Users/a/Old"]
        backend.failingPaths = ["/Users/a/Old"]
        let s = makeStore()
        let report = s.load()
        #expect(report == FolderAccessStore.LoadReport(restored: 1, refreshed: 0, dropped: 0))
        #expect(s.covers("/Users/a/Old"))
        #expect(persistence.stored == [Data("/Users/a/Old".utf8)])
        #expect(backend.started.count == backend.stopped.count)
    }

    @Test("Doppelte Bookmarks auf denselben Ordner werden zusammengefasst")
    func duplicatesOnLoad() {
        persistence.stored = [Data("/Users/a/X".utf8), Data("/users/a/x".utf8), Data("/Users/a/X/sub".utf8)]
        let s = makeStore()
        _ = s.load()
        #expect(s.grants.map(\.path) == ["/Users/a/X"])
        #expect(persistence.stored == [Data("/Users/a/X".utf8)])
    }

    @Test("Bookmark lässt sich nicht anlegen: Freigabe gilt nur für diese Sitzung")
    func sessionOnlyGrant() {
        backend.failingPaths = ["/Volumes/Net"]
        let s = makeStore()
        #expect(s.grant(path: "/Volumes/Net") == .granted(persisted: false))
        #expect(s.covers("/Volumes/Net/a"))
        #expect(persistence.stored.isEmpty)
        let relaunched = FolderAccessStore(backend: backend, persistence: persistence)
        _ = relaunched.load()
        #expect(!relaunched.covers("/Volumes/Net/a"))
    }

    @Test("Zugriff mit Zählung: start beim ersten, stop beim letzten Lease, doppeltes Ende zählt nicht")
    func leases() throws {
        let s = makeStore()
        _ = s.grant(path: "/Users/a/Documents")
        let a = try #require(s.beginAccess(for: "/Users/a/Documents"))
        let b = try #require(s.beginAccess(for: "/Users/a/Documents/sub"))
        #expect(backend.started == ["/Users/a/Documents"])
        #expect(s.activeAccessCount == 1)
        s.endAccess(a)
        #expect(backend.stopped.isEmpty)
        s.endAccess(a)
        #expect(backend.stopped.isEmpty)
        s.endAccess(b)
        #expect(backend.stopped == ["/Users/a/Documents"])
        #expect(s.activeAccessCount == 0)
        // Ohne Freigabe kein Lease.
        #expect(s.beginAccess(for: "/Users/b") == nil)
    }

    @Test("startAccessing liefert false (z. B. Freigabe aus Öffnen-Dialog dieser Sitzung): Lease gilt, aber kein stop")
    func leaseWithoutStart() throws {
        backend.startResult = false
        let s = makeStore()
        _ = s.grant(path: "/Users/a/Documents")
        let a = try #require(s.beginAccess(for: "/Users/a/Documents/x"))
        s.endAccess(a)
        #expect(backend.started == ["/Users/a/Documents"])
        #expect(backend.stopped.isEmpty)
    }

    @Test("Widerrufen: entfernt, speichert, beendet laufenden Zugriff genau einmal")
    func revoke() throws {
        let s = makeStore()
        _ = s.grant(path: "/Users/a/Documents")
        _ = s.grant(path: "/Volumes/USB")
        let lease = try #require(s.beginAccess(for: "/Users/a/Documents/x"))
        #expect(s.revoke(path: "/users/a/documents/"))
        #expect(!s.covers("/Users/a/Documents/x"))
        #expect(backend.stopped == ["/Users/a/Documents"])
        #expect(persistence.stored == [Data("/Volumes/USB".utf8)])
        s.endAccess(lease)
        #expect(backend.stopped == ["/Users/a/Documents"])
        #expect(!s.revoke(path: "/Users/a/Documents"))
        #expect(!s.revoke(path: "/Volumes/USB/sub"))
    }

    @Test("Widerrufen und neu freigeben: Ende eines alten Leases beendet den neuen Zugriff nicht")
    func revokeRegrantStaleLease() throws {
        let s = makeStore()
        _ = s.grant(path: "/Volumes/USB")
        let old = try #require(s.beginAccess(for: "/Volumes/USB/a"))
        #expect(s.isActive(old))
        #expect(s.revoke(path: "/Volumes/USB"))
        #expect(!s.isActive(old))
        #expect(backend.stopped == ["/Volumes/USB"])
        _ = s.grant(path: "/Volumes/USB")
        let fresh = try #require(s.beginAccess(for: "/Volumes/USB"))
        #expect(backend.started == ["/Volumes/USB", "/Volumes/USB"])
        s.endAccess(old)
        #expect(backend.stopped == ["/Volumes/USB"])
        #expect(s.activeAccessCount == 1)
        #expect(s.isActive(fresh))
        s.endAccess(fresh)
        #expect(backend.stopped == ["/Volumes/USB", "/Volumes/USB"])
        #expect(s.activeAccessCount == 0)
    }

    @Test("Symlink in der Freigabe: auch der aufgelöste Pfad ist gedeckt (/tmp → /private/tmp)")
    func resolvedGrantPath() throws {
        let links = ["/tmp": "/private/tmp", "/Users/a/Ext": "/Volumes/X"]
        let s = FolderAccessStore(backend: backend, persistence: persistence) { path in
            links.first { path == $0.key || path.hasPrefix($0.key + "/") }
                .map { $0.value + path.dropFirst($0.key.count) } ?? path
        }
        _ = s.grant(path: "/tmp")
        _ = s.grant(path: "/Users/a/Ext")
        #expect(s.covers("/private/tmp/scan/x"))
        #expect(s.covers("/tmp/scan"))
        #expect(s.covers("/Volumes/X/sub"))
        #expect(s.grantedAncestor(for: "/Volumes/X/sub") == "/Users/a/Ext")
        #expect(!s.covers("/private/tmpfoo"))
        #expect(!s.covers("/Volumes/Y"))
        let lease = try #require(s.beginAccess(for: "/private/tmp/scan"))
        #expect(lease.grantPath == "/tmp")
        #expect(backend.started == ["/tmp"])
        // Umgekehrt: Freigabe über den echten Pfad deckt den Symlink-Pfad.
        let t = FolderAccessStore(backend: FakeBookmarks(), persistence: MemoryGrantPersistence()) { path in
            links.first { path == $0.key || path.hasPrefix($0.key + "/") }
                .map { $0.value + path.dropFirst($0.key.count) } ?? path
        }
        _ = t.grant(path: "/private/tmp")
        #expect(t.covers("/tmp/scan"))
        // Nach einem Neustart wird der aufgelöste Pfad neu bestimmt.
        let relaunched = FolderAccessStore(backend: backend, persistence: persistence) { path in
            links.first { path == $0.key || path.hasPrefix($0.key + "/") }
                .map { $0.value + path.dropFirst($0.key.count) } ?? path
        }
        _ = relaunched.load()
        #expect(relaunched.covers("/private/tmp/scan"))
    }

    @Test("Symlink im echten Dateisystem: realpath als Standard")
    func resolvedGrantPathOnDisk() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("Ziel")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let s = makeStore()
        _ = s.grant(path: link.path)
        let real = try #require(FolderAccessStore.resolvedPath(target.path))
        #expect(s.covers(real + "/datei"))
        #expect(s.covers(link.path + "/datei"))
    }

    @Test("Liste der Freigaben ist sortiert")
    func sortedGrants() {
        let s = makeStore()
        _ = s.grant(path: "/Volumes/Z")
        _ = s.grant(path: "/Users/a/Documents")
        _ = s.grant(path: "/Volumes/A")
        #expect(s.grants.map(\.path) == ["/Users/a/Documents", "/Volumes/A", "/Volumes/Z"])
        #expect(s.grants.allSatisfy { $0.isPersistent })
    }

    @Test("UserDefaults-Ablage: speichert und liest die Bookmarks unter dem Schlüssel")
    func userDefaultsPersistence() throws {
        let suite = "diskrings-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = UserDefaultsGrantPersistence(defaults: defaults)
        #expect(p.load().isEmpty)
        p.save([Data([1, 2]), Data([3])])
        #expect(UserDefaultsGrantPersistence(defaults: defaults).load() == [Data([1, 2]), Data([3])])
    }
}
