@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Schutzliste für das Löschen", .language("de"))
struct ProtectedPathsTests {
    let p = ProtectedPaths(home: "/Users/stefan", appBundlePath: "/Applications/DiskRings.app",
                           volumeRoots: ["/", "/Volumes/Backup", "/System/Volumes/Data"])

    @Test("Systembereiche samt Inhalt sind geschützt", arguments: [
        "/System", "/System/Library/Fonts", "/usr", "/usr/bin/ls", "/usr/share/man", "/bin", "/bin/zsh",
        "/sbin/mount", "/private/var/db", "/private/var/db/receipts", "/Library/Apple",
        "/Library/Apple/System/Library",
    ])
    func systemAreas(path: String) {
        guard case .system = p.reason(for: path) else {
            Issue.record("\(path) sollte als Systembereich geschützt sein, ist: \(String(describing: p.reason(for: path)))")
            return
        }
    }

    @Test("/usr/local ist ausgenommen", arguments: ["/usr/local", "/usr/local/bin", "/usr/local/Cellar/foo"])
    func usrLocal(path: String) {
        #expect(p.reason(for: path) == nil)
    }

    @Test("Volume-Wurzeln, Home und ~/Library als Ganzes")
    func wholeFolders() {
        #expect(p.reason(for: "/") == .volumeRoot)
        #expect(p.reason(for: "/Volumes/Backup") == .volumeRoot)
        #expect(p.reason(for: "/Users/stefan") == .home)
        #expect(p.reason(for: "/Users/stefan/") == .home)
        #expect(p.reason(for: "/Users/stefan/Library") == .homeLibrary)
    }

    @Test("Inhalt von Home, ~/Library und anderen Volumes darf in den Papierkorb", arguments: [
        "/Users/stefan/Downloads", "/Users/stefan/Downloads/x.zip", "/Users/stefan/Library/Caches",
        "/Users/stefan/Library/Caches/com.foo", "/Volumes/Backup/alt", "/Library/Caches", "/Applications/Foo.app",
        "/private/var/folders/xy/tmp", "/Users/stefan/Library Kopie", "/Users/stefanie",
    ])
    func allowed(path: String) {
        #expect(p.reason(for: path) == nil, "\(path)")
    }

    @Test("Die laufende App samt Inhalt")
    func runningApp() {
        #expect(p.reason(for: "/Applications/DiskRings.app") == .runningApp)
        #expect(p.reason(for: "/Applications/DiskRings.app/Contents/MacOS/DiskRings") == .runningApp)
    }

    @Test("Ordner, die einen geschützten Bereich enthalten, sind ebenfalls geschützt")
    func ancestors() {
        #expect(p.reason(for: "/Users") == .containsProtected(path: "/Users/stefan", reason: .home))
        #expect(p.reason(for: "/Applications") == .containsProtected(path: "/Applications/DiskRings.app",
                                                                      reason: .runningApp))
        #expect(p.reason(for: "/Library") == .containsProtected(path: "/Library/Apple", reason: .system("/Library/Apple")))
        #expect(p.reason(for: "/private") != nil)
        #expect(p.reason(for: "/private/var") != nil)
        #expect(p.reason(for: "/Volumes") != nil)
    }

    @Test("Normalisierung: Groß-/Kleinschreibung, .., doppelte Schrägstriche, /var, Firmlinks, NFD")
    func normalization() {
        #expect(p.isProtected("/system/library"))
        #expect(p.isProtected("/USR/bin"))
        #expect(p.isProtected("//usr///bin/"))
        #expect(p.isProtected("/Users/stefan/Downloads/../Library"))
        #expect(p.isProtected("/Users/stefan/./"))
        #expect(p.isProtected("/var/db/receipts"))
        #expect(!p.isProtected("/var/folders/ab"))
        #expect(p.reason(for: "/System/Volumes/Data/Users/stefan") == .home)
        #expect(!p.isProtected("/System/Volumes/Data/Users/stefan/Downloads"))
        #expect(p.isProtected("/System/Volumes/Data"))
        #expect(p.isProtected("/usr/local/../bin"))
        // Home mit Umlaut, einmal NFC, einmal NFD.
        let q = ProtectedPaths(home: "/Users/j\u{00FC}rgen", appBundlePath: nil, volumeRoots: ["/"])
        #expect(q.reason(for: "/Users/ju\u{0308}rgen") == .home)
        #expect(q.reason(for: "/Users/ju\u{0308}rgen/Library") == .homeLibrary)
    }

    @Test("Ohne App-Bündel (Tests, swift run) bleibt die übrige Liste aktiv")
    func noApp() {
        let q = ProtectedPaths(home: "/Users/x", appBundlePath: nil, volumeRoots: [])
        #expect(q.reason(for: "/") == .volumeRoot)
        #expect(q.reason(for: "/Applications") == nil)
    }

    @Test("Begründungen sind lesbar")
    func messages() {
        #expect(ProtectedPaths.Reason.system("/usr").message.contains("/usr"))
        #expect(p.reason(for: "/Users")!.message.contains("Benutzerordner"))
    }

    @Test("Einhängepunkte des Systems werden gefunden, „/“ ist immer dabei")
    func mountedRoots() {
        #expect(ProtectedPaths.mountedVolumeRoots().contains("/"))
        let real = ProtectedPaths()
        #expect(real.isProtected("/"))
        #expect(real.isProtected(NSHomeDirectory()))
        #expect(!real.isProtected(FileManager.default.temporaryDirectory.appendingPathComponent("x").path))
    }
}
