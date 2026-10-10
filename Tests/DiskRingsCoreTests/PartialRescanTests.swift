@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Teil-Rescan in der Oberfläche: Warteschlange, Einhängen, Hinweis", .timeLimit(.minutes(2)), .language("de"))
struct PartialRescanTests {
    @Test("Warteschlange: voller Scan blockiert, doppelte und abgedeckte Pfade, Vorfahr ersetzt Nachfahren")
    func queue() {
        var q = RescanQueue()
        #expect(q.request("/a/b", fullScanRunning: true) == .blockedByFullScan)
        #expect(q.isEmpty)
        guard case .start(let id1, let c1) = q.request("/a/b", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        #expect(c1.isEmpty)
        #expect(q.request("/a/b", fullScanRunning: false) == .alreadyCovered(by: "/a/b"))
        #expect(q.request("/a/b/c", fullScanRunning: false) == .alreadyCovered(by: "/a/b"))
        // Unabhängiger Ordner läuft parallel; „/a/bc“ ist kein Nachfahre von „/a/b“.
        guard case .start(let id2, let c2) = q.request("/a/bc", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        #expect(c2.isEmpty)
        #expect(Set(q.paths) == ["/a/b", "/a/bc"])
        // Vorfahr: ersetzt beide.
        guard case .start(let id3, let c3) = q.request("/a", fullScanRunning: false) else {
            Issue.record("Start erwartet"); return
        }
        #expect(Set(c3) == [id1, id2])
        #expect(q.paths == ["/a"])
        // Ergebnisse ersetzter Jobs werden verworfen.
        #expect(q.finish(id1) == .discard)
        #expect(q.job(covering: "/a/x/y")?.id == id3)
        #expect(q.finish(id3) == .apply)
        #expect(q.isEmpty)
        _ = q.request("/x", fullScanRunning: false)
        #expect(q.cancelAll().count == 1 && q.isEmpty)
        #expect(RescanQueue.covers("/", "/x"))
    }

    @Test("Zwei parallele Teil-Rescans: beide Ergebnisse landen im aktuellen Baum")
    func parallelMerges() throws {
        let fx = try Fixture()
        try fx.file("a/x.bin", size: 100_000)
        try fx.file("b/y.bin", size: 100_000)
        let options = ScanOptions(workerCount: 2)
        let t0 = try ScanEngine(options: options).scanBlocking(fx.root).tree
        try fx.file("a/neu.bin", size: 1_000_000)
        try fx.file("b/neu.bin", size: 2_000_000)
        // Beide Scans laufen gegen den Stand t0 los …
        let sa = try PartialRescan.scan(fx.path("a"), options: options)
        let sb = try PartialRescan.scan(fx.path("b"), options: options)
        // … und werden nacheinander in den jeweils aktuellen Baum eingehängt.
        let m1 = try #require(PartialRescan.merge(sa?.tree, path: fx.path("a"), into: t0))
        let m2 = try #require(PartialRescan.merge(sb?.tree, path: fx.path("b"), into: m1.tree))
        expectValidTree(m2.tree)
        expectEquivalent(m2.tree, try ScanEngine(options: options).scanBlocking(fx.root).tree)
        #expect(m1.after - m1.before >= 1_000_000)
        #expect(m2.after - m2.before >= 2_000_000)
        #expect(m1.edit.translate(0) == 0)
    }

    @Test("Ordner existiert nicht mehr: Knoten wird entfernt, Hinweis nennt das")
    func folderGone() throws {
        let fx = try Fixture()
        try fx.file("weg/x.bin", size: 300_000)
        try fx.file("bleibt/y.bin", size: 100_000)
        let options = ScanOptions(workerCount: 2)
        let t0 = try ScanEngine(options: options).scanBlocking(fx.root).tree
        let size = try #require(t0.index(ofPath: "weg").map { t0.node($0).allocatedSize })
        try FileManager.default.removeItem(atPath: fx.path("weg"))
        let scanned = try PartialRescan.scan(fx.path("weg"), options: options)
        #expect(scanned == nil)
        let m = try #require(PartialRescan.merge(nil, path: fx.path("weg"), into: t0))
        #expect(m.removed)
        #expect(m.tree.index(ofPath: "weg") == nil)
        #expect(m.tree.root.allocatedSize == t0.root.allocatedSize - size)
        #expect(m.summary().hasPrefix("weg: nicht mehr vorhanden (\u{2212}"))
        // Pfad, der gar nicht im Baum steht (z. B. schon entfernt): nichts zu tun.
        #expect(PartialRescan.merge(nil, path: fx.path("weg"), into: m.tree) == nil)
        // Die Wurzel selbst verschwunden: kein Einhängen möglich.
        #expect(PartialRescan.merge(nil, path: fx.root, into: t0) == nil)
    }

    @Test("Wurzel neu einlesen: Name aus dem Wurzelpfad")
    func rootRescan() throws {
        let fx = try Fixture()
        try fx.file("x.bin", size: 100_000)
        let options = ScanOptions(workerCount: 1)
        let t0 = try ScanEngine(options: options).scanBlocking(fx.root).tree
        try fx.file("y.bin", size: 100_000)
        let s = try PartialRescan.scan(fx.root, options: options)
        let m = try #require(PartialRescan.merge(s?.tree, path: fx.root, into: t0))
        #expect(m.name == (fx.root as NSString).lastPathComponent)
        #expect(m.summary().contains("→"))
    }

    @Test("Hinweistext „Name: alt → neu (±Δ)“")
    func summaryText() {
        #expect(PartialRescan.summary(name: "Library", before: 182_400_000_000, after: 176_100_000_000, removed: false)
            == "Library: 182,4\u{00A0}GB → 176,1\u{00A0}GB (\u{2212}6,3\u{00A0}GB)")
        #expect(PartialRescan.summary(name: "x", before: 1_000_000, after: 3_500_000, removed: false)
            == "x: 1,0\u{00A0}MB → 3,5\u{00A0}MB (+2,5\u{00A0}MB)")
        #expect(PartialRescan.summary(name: "x", before: 5000, after: 5000, removed: false)
            == "x: 5\u{00A0}KB (unverändert)")
    }

    @Test("Geschätzter Fortschritt aus alter Größe")
    func progressEstimate() {
        #expect(PartialRescan.estimatedProgress(scannedBytes: 50, previousSize: 100) == 0.5)
        #expect(PartialRescan.estimatedProgress(scannedBytes: 500, previousSize: 100) == 0.97)
        #expect(PartialRescan.estimatedProgress(scannedBytes: 5, previousSize: 0) == nil)
    }
}

@Suite("Suche nach Namen")
struct TreeSearchTests {
    @Test("Teilzeichenfolge, Groß-/Kleinschreibung, Akzente, NFD, Sortierung nach Größe")
    func search() throws {
        var b = ScanTreeBuilder(rootName: "r")
        let d = b.directory("Dokumente")
        b.file("Müller Rechnung.pdf", size: 3000, in: d)
        b.file("mu\u{0308}ller-nfd.txt", size: 5000, in: d)
        b.file("MULLER.txt", size: 1000, in: d)
        b.file("anderes.txt", size: 9000)
        let sub = b.directory("muller-ordner")
        b.file("x", size: 10, in: sub)
        let tree = b.build(rootPath: "/r")
        let r = TreeSearch.search("muller", in: tree)
        #expect(r.total == 4)
        #expect(r.matches.map { tree.name(of: $0) } == ["mu\u{0308}ller-nfd.txt", "Müller Rechnung.pdf", "MULLER.txt",
                                                        "muller-ordner"])
        #expect(TreeSearch.search("MÜLLER", in: tree).total == 4)
        #expect(TreeSearch.search("  ", in: tree).total == 0)
        #expect(TreeSearch.search("txt", in: tree, limit: 1).matches.count == 1)
        #expect(TreeSearch.search("txt", in: tree, limit: 1).total == 3)
        let docs = try #require(tree.index(ofPath: "Dokumente"))
        #expect(TreeSearch.search("txt", in: tree, under: docs).total == 2)
        #expect(TreeSearch.search("gibtsnicht", in: tree).matches.isEmpty)
    }

    @Test("Tote Knoten nach dem Entfernen werden nicht gefunden")
    func deadNodes() throws {
        let tree = smallTree()
        let movies = try #require(tree.index(ofPath: "Movies"))
        let t = tree.removingNode(at: movies, compactIfNeeded: false).tree
        #expect(t.deadCount > 0)
        #expect(TreeSearch.search("film", in: t).total == 0)
    }

    @Test("Performance: Suche in 2 Mio. Knoten")
    func performance() throws {
        let tree = try RescanTests.syntheticTree()
        let start = DispatchTime.now().uptimeNanoseconds
        let r = TreeSearch.search("Datei199.", in: tree)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        print("[perf] Suche in \(tree.count) Knoten: \(ms) ms, \(r.total) Treffer")
        #expect(r.total == 10_000)
        #if DEBUG
        #expect(ms < 10_000)
        #else
        #expect(ms < 1_000)
        #endif
    }
}

@Suite("Animation nach Änderungen am Baum")
struct EditTransitionTests {
    @Test("Entfernter Knoten schrumpft, Geschwister wandern, Endbild = neues Layout")
    func removal() throws {
        let tree = smallTree()
        let movies = try #require(tree.index(ofPath: "Movies"))
        let chain = tree.removingNodes([movies])
        let old = SunburstLayout(tree: tree, focus: 0)
        let new = SunburstLayout(tree: chain.tree, focus: 0)
        let tr = EditTransition(from: old, to: new, translate: chain.translate)
        #expect(tr.matchedCount >= new.arcs.filter { $0.kind == .node }.count)
        // Am Anfang: alte Winkel der verbleibenden Arcs.
        let f0 = tr.frame(at: 0, rings: 6)
        let lib = try #require(tree.index(ofPath: "Library"))
        let oldLib = try #require(old.arcIndex(ofNode: lib).map { old.arcs[$0] })
        let newLibIndex = try #require(chain.translate(lib).flatMap { new.arcIndex(ofNode: $0) })
        let d0 = try #require(f0.first { $0.isFromTarget && $0.arcIndex == newLibIndex })
        #expect(abs(d0.startAngle - oldLib.startAngle) < 1e-9 && abs(d0.endAngle - oldLib.endAngle) < 1e-9)
        // Das entfernte Segment ist zu Beginn voll sichtbar …
        let oldMovies = try #require(old.arcIndex(ofNode: movies))
        #expect(f0.contains { !$0.isFromTarget && $0.arcIndex == oldMovies && $0.opacity == 1 })
        // … in der Mitte halb so breit und am Ende verschwunden.
        let fm = tr.frame(at: 0.5, rings: 6)
        let mid = try #require(fm.first { !$0.isFromTarget && $0.arcIndex == oldMovies })
        #expect(abs((mid.endAngle - mid.startAngle) - old.arcs[oldMovies].span / 2) < 1e-9)
        let f1 = tr.frame(at: 1, rings: 6)
        #expect(f1.allSatisfy { $0.isFromTarget })
        for d in f1 {
            let a = new.arcs[d.arcIndex]
            #expect(abs(d.startAngle - a.startAngle) < 1e-9 && abs(d.endAngle - a.endAngle) < 1e-9)
        }
    }

    @Test("Segmente der Volume-Wurzel finden ihr Gegenstück (je Teil der Systemdaten eines)")
    func volumeSegmentsMatched() throws {
        let tree = smallTree()
        let movies = try #require(tree.index(ofPath: "Movies"))
        let chain = tree.removingNodes([movies])
        let o = SunburstOptions(rootSegments: .full)
        let old = SunburstLayout(tree: tree, options: o), new = SunburstLayout(tree: chain.tree, options: o)
        let tr = EditTransition(from: old, to: new, translate: chain.translate)
        for (j, a) in new.arcs.enumerated() where a.kind.isVolumeSegment {
            let i = tr.match[j]
            #expect(i >= 0)
            #expect(old.arcs[i].kind == a.kind && old.arcs[i].part == a.part)
        }
        #expect(!tr.orphans.contains { old.arcs[$0].kind.isVolumeSegment })
    }

    @Test("Neue Arcs wachsen aus ihrer Mitte")
    func growth() throws {
        let tree = smallTree()
        var b = ScanTreeBuilder(rootName: "Movies")
        b.file("film.mov", size: 9_000_000)
        b.file("neu.mov", size: 20_000_000)
        let sub = b.build(rootPath: "/Users/demo/Movies")
        let movies = try #require(tree.index(ofPath: "Movies"))
        let edit = tree.replacingSubtree(at: movies, with: sub)
        let tr = EditTransition(from: SunburstLayout(tree: tree), to: SunburstLayout(tree: edit.tree),
                                translate: edit.translate)
        let neu = try #require(edit.tree.index(ofPath: "Movies/neu.mov"))
        let j = try #require(tr.to.arcIndex(ofNode: neu))
        #expect(!tr.frame(at: 0, rings: 6).contains { $0.isFromTarget && $0.arcIndex == j })
        let d = try #require(tr.frame(at: 0.5, rings: 6).first { $0.isFromTarget && $0.arcIndex == j })
        #expect(abs((d.endAngle - d.startAngle) - tr.to.arcs[j].span / 2) < 1e-9)
        #expect(d.opacity == 0.5)
    }
}
