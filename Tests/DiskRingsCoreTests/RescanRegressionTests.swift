@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Regressionstests zu Befunden aus dem Review (Teil-Rescan, Hardlinks,
/// Warteschlange). Alles läuft in temporären Fixture-Bäumen.
@Suite("Teil-Rescan: Regressionen (Symlinks, Hardlinks, Warteschlange)", .timeLimit(.minutes(2)))
struct RescanRegressionTests {
    let engine = ScanEngine(options: ScanOptions(workerCount: 2))

    // MARK: M1 – Teil-Rescan folgt keinem Symlink

    /// Ordner `a` (100 KB) wird durch einen Symlink auf einen 5-MB-Ordner
    /// außerhalb ersetzt; ein frischer Scan zählt den Symlink nicht mit.
    private func symlinkFixture() throws -> (Fixture, ScanTree) {
        let fx = try Fixture()
        try fx.file("root/a/f.bin", size: 100_000)
        try fx.file("root/b/g.bin", size: 10_000)
        let t0 = try engine.scanBlocking(fx.path("root")).tree
        try fx.file("external/big.bin", size: 5_000_000)
        try FileManager.default.removeItem(atPath: fx.path("root/a"))
        try fx.symlink("root/a", to: fx.path("external"))
        return (fx, t0)
    }

    @Test("PartialRescan: Ordner ist jetzt ein Symlink → Symlink-Blatt, kein Ziel-Inhalt")
    func partialRescanDoesNotFollowSymlink() throws {
        let (fx, t0) = try symlinkFixture()
        defer { fx.remove() }
        let path = fx.path("root/a")
        let sub = try PartialRescan.scan(path, options: engine.options)
        let m = try #require(PartialRescan.merge(sub?.tree, path: path, into: t0))
        expectValidTree(m.tree)
        let fresh = try engine.scanBlocking(fx.path("root")).tree
        expectEquivalent(m.tree, fresh)
        let a = try #require(m.tree.index(ofPath: "a"))
        #expect(m.tree.node(a).flags.contains(.symlink))
        #expect(!m.tree.node(a).flags.contains(.directory))
        #expect(m.tree.root.allocatedSize < 1_000_000)
    }

    @Test("rescanBlocking(path:): Ordner ist jetzt ein Symlink → wie ein frischer Scan")
    func engineRescanDoesNotFollowSymlink() throws {
        let (fx, t0) = try symlinkFixture()
        defer { fx.remove() }
        let r = try engine.rescanBlocking(path: fx.path("root/a"), in: t0)
        expectValidTree(r.tree)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.path("root")).tree)
        #expect(r.tree.root.allocatedSize < 1_000_000)
    }

    @Test("Ordner ist jetzt eine Datei → Datei-Blatt")
    func folderReplacedByFile() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("root/a/f.bin", size: 100_000)
        let t0 = try engine.scanBlocking(fx.path("root")).tree
        try FileManager.default.removeItem(atPath: fx.path("root/a"))
        try fx.file("root/a", size: 20_000)
        let path = fx.path("root/a")
        let sub = try PartialRescan.scan(path, options: engine.options)
        let m = try #require(PartialRescan.merge(sub?.tree, path: path, into: t0))
        expectValidTree(m.tree)
        expectEquivalent(m.tree, try engine.scanBlocking(fx.path("root")).tree)
    }

    @Test("Symlink auf die Wurzel: Rescan der Wurzel folgt weiterhin (wie der Scan)")
    func rootRescanStillResolves() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("real/x.bin", size: 50_000)
        try fx.symlink("link", to: fx.path("real"))
        let t0 = try engine.scanBlocking(fx.path("link")).tree
        #expect(t0.rootPath == fx.path("real"))
        try fx.file("real/y.bin", size: 70_000)
        let r = try engine.rescanBlocking(subtree: ScanTree.rootIndex, in: t0)
        expectValidTree(r.tree)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.path("real")).tree)
        let sub = try PartialRescan.scan(t0.rootPath, options: engine.options, followSymlink: true)
        #expect(sub?.tree.root.flags.contains(.directory) == true)
    }

    // MARK: Symlink in der Mitte des Pfads

    /// `root/a/b` wird gescannt; danach wird `a` durch einen Symlink auf
    /// einen Ordner außerhalb ersetzt, der ebenfalls ein `b` (5 MB) enthält.
    private func middleSymlinkFixture() throws -> (Fixture, ScanTree) {
        let fx = try Fixture()
        try fx.file("root/a/b/f.bin", size: 100_000)
        try fx.file("root/c/g.bin", size: 10_000)
        let t0 = try engine.scanBlocking(fx.path("root")).tree
        try fx.file("external/b/big.bin", size: 5_000_000)
        try FileManager.default.removeItem(atPath: fx.path("root/a"))
        try fx.symlink("root/a", to: fx.path("external"))
        return (fx, t0)
    }

    @Test("scanBlocking ohne Wurzel-Symlink: Symlink weiter oben im Pfad → Fehler, nichts gelesen")
    func scanRejectsSymlinkInParentChain() throws {
        let (fx, _) = try middleSymlinkFixture()
        defer { fx.remove() }
        #expect(throws: ScanError.ancestorChanged(fx.path("root/a/b"), ancestor: fx.path("root/a"))) {
            try engine.scanBlocking(fx.path("root/a/b"), followRootSymlink: false)
        }
        #expect(throws: ScanError.ancestorChanged(fx.path("root/a/b"), ancestor: fx.path("root/a"))) {
            try PartialRescan.scan(fx.path("root/a/b"), options: engine.options)
        }
    }

    @Test("rescanBlocking(path:): Symlink weiter oben → nächster intakter Vorfahr wird neu gelesen")
    func engineRescanRedirectsToChangedAncestor() throws {
        let (fx, t0) = try middleSymlinkFixture()
        defer { fx.remove() }
        let r = try engine.rescanBlocking(path: fx.path("root/a/b"), in: t0)
        #expect(r.path == fx.path("root/a"))
        expectValidTree(r.tree)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.path("root")).tree)
        #expect(r.tree.root.allocatedSize < 1_000_000)
        let a = try #require(r.tree.index(ofPath: "a"))
        #expect(r.tree.node(a).flags.contains(.symlink))
    }

    @Test("Vorfahr verschwunden → Vorfahr wird entfernt, nicht nur der Unterordner")
    func engineRescanRemovesVanishedAncestor() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("root/a/b/f.bin", size: 100_000)
        try fx.file("root/c/g.bin", size: 10_000)
        let t0 = try engine.scanBlocking(fx.path("root")).tree
        try FileManager.default.removeItem(atPath: fx.path("root/a"))
        let r = try engine.rescanBlocking(path: fx.path("root/a/b"), in: t0)
        #expect(r.removed)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.path("root")).tree)
    }

    @Test("Intakte Kette: Unicode-Namen im Pfad stören die Prüfung nicht")
    func unicodeChainStillScans() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("root/Übersicht/日本/f.bin", size: 30_000)
        let sub = try PartialRescan.scan(fx.path("root/Übersicht/日本"), options: engine.options)
        #expect(sub?.tree.root.allocatedSize ?? 0 >= 30_000)
    }

    // MARK: L1 – Rescan einer Hardlink-Datei

    @Test("Rescan einer Datei mit Hardlink: Gruppe bleibt einmal gezählt, Tabelle gültig")
    func hardlinkFileRescan() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        let file = try fx.file("h/x/file", size: 3_000_000)
        try fx.hardlink(file, "h/y/link")
        let t0 = try engine.scanBlocking(fx.path("h")).tree
        let before = t0.root.allocatedSize
        let r = try engine.rescanBlocking(path: fx.path("h/x/file"), in: t0)
        expectValidTree(r.tree)
        #expect(r.tree.root.allocatedSize == before)
        let f = try #require(r.tree.index(ofPath: "x/file"))
        #expect(r.tree.node(f).allocatedSize >= 3_000_000)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.path("h")).tree)
        // Auch der zweite Rescan (jetzt über den Link) bleibt stabil.
        let r2 = try engine.rescanBlocking(path: fx.path("h/y/link"), in: r.tree)
        expectValidTree(r2.tree)
        #expect(r2.tree.root.allocatedSize == before)
    }

    // MARK: M2 – Warteschlange: veraltete Ergebnisse nicht über neuere Änderungen

    @Test("Ohne Änderung: ein Lauf, Ergebnis übernehmen")
    func queueSingleRun() {
        var q = RescanQueue()
        guard case .start(let id, _) = q.request("/r/a", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        q.noteEdit(at: "/r/b/x") // anderer Ordner
        q.noteEdit(at: "/r") // Vorfahr: liegt nicht unter dem Job
        #expect(q.finish(id) == .apply)
        #expect(q.isEmpty)
    }

    @Test("Abgedeckte Anfrage während des Laufs → Job läuft noch einmal")
    func queueCoveredRequestReruns() {
        var q = RescanQueue()
        guard case .start(let id, _) = q.request("/r/a", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        #expect(q.request("/r/a/sub", fullScanRunning: false) == .alreadyCovered(by: "/r/a"))
        #expect(q.finish(id) == .rerun)
        // Der Job bleibt (gleiche ID) in der Liste und läuft neu.
        #expect(q.paths == ["/r/a"])
        #expect(q.job(covering: "/r/a/sub")?.id == id)
        #expect(q.finish(id) == .apply)
        #expect(q.isEmpty)
    }

    @Test("Änderung (Papierkorb/Undo) unter einem laufenden Pfad → Job läuft noch einmal")
    func queueEditUnderRunningPathReruns() {
        var q = RescanQueue()
        guard case .start(let id, _) = q.request("/r/a", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        q.noteEdit(at: "/r/a/trashed")
        q.noteEdit(at: "/r/a/second") // mehrfach: trotzdem nur ein Neulauf
        #expect(q.finish(id) == .rerun)
        #expect(q.finish(id) == .apply)
        // Ersetzter oder abgebrochener Job: verwerfen.
        guard case .start(let id2, _) = q.request("/r/b", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        q.noteEdit(at: "/r/b/x")
        _ = q.cancelAll()
        #expect(q.finish(id2) == .discard)
    }

    @Test("Szenario: Papierkorb während des Rescans – veraltetes Ergebnis brächte das Element zurück")
    func staleResultScenario() throws {
        let fx = try Fixture()
        defer { fx.remove() }
        try fx.file("a/keep.bin", size: 100_000)
        try fx.file("a/trash.bin", size: 2_000_000)
        let t0 = try engine.scanBlocking(fx.root).tree
        var q = RescanQueue()
        guard case .start(let id, _) = q.request(fx.path("a"), fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        // Der Job hat den Ordner schon gelesen …
        let stale = try PartialRescan.scan(fx.path("a"), options: engine.options)
        // … dann wird eine Datei darin in den Papierkorb gelegt (hier: entfernt).
        try FileManager.default.removeItem(atPath: fx.path("a/trash.bin"))
        let edited = t0.removingNodes(atPaths: [fx.path("a/trash.bin")]).tree
        q.noteEdit(at: fx.path("a/trash.bin"))
        // Das veraltete Ergebnis würde die Datei zurückbringen …
        let wrong = try #require(PartialRescan.merge(stale?.tree, path: fx.path("a"), into: edited))
        #expect(wrong.tree.index(ofPath: "a/trash.bin") != nil)
        // … deshalb verlangt die Warteschlange einen Neulauf.
        #expect(q.finish(id) == .rerun)
        let fresh = try PartialRescan.scan(fx.path("a"), options: engine.options)
        let right = try #require(PartialRescan.merge(fresh?.tree, path: fx.path("a"), into: edited))
        #expect(q.finish(id) == .apply)
        #expect(right.tree.index(ofPath: "a/trash.bin") == nil)
        expectEquivalent(right.tree, try engine.scanBlocking(fx.root).tree)
    }
}
