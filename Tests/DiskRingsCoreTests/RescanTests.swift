@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Vergleicht zwei Bäume strukturell (Namen, Größen, Dateianzahl, Flags und
/// Reihenfolge der Kinder), unabhängig von Indizes und toten Knoten.
func expectEquivalent(_ a: ScanTree, _ b: ScanTree, sourceLocation: SourceLocation = #_sourceLocation) {
    var stack: [(Int32, Int32)] = [(0, 0)]
    var problems: [String] = []
    while let (i, j) = stack.popLast(), problems.count < 10 {
        let x = a.nodes[Int(i)], y = b.nodes[Int(j)]
        let path = a.path(of: i)
        if !a.nameBytes(of: i).elementsEqual(b.nameBytes(of: j)) { problems.append("Name \(path)") }
        if x.allocatedSize != y.allocatedSize || x.logicalSize != y.logicalSize || x.fileCount != y.fileCount {
            problems.append("\(path): \(x.allocatedSize)/\(x.logicalSize)/\(x.fileCount) vs. \(y.allocatedSize)/\(y.logicalSize)/\(y.fileCount)")
        }
        if x.flags.subtracting(.dead) != y.flags.subtracting(.dead) { problems.append("Flags \(path)") }
        if x.childCount != y.childCount { problems.append("Kinderzahl \(path): \(x.childCount) vs. \(y.childCount)"); continue }
        for (c, d) in zip(a.childIndices(of: i), b.childIndices(of: j)) { stack.append((c, d)) }
    }
    #expect(problems.isEmpty, "Bäume unterscheiden sich: \(problems)", sourceLocation: sourceLocation)
}

@Suite("Teil-Rescan und veränderbarer Baum", .timeLimit(.minutes(2)))
struct RescanTests {
    let engine = ScanEngine(options: ScanOptions(workerCount: 2))

    func fullScan(_ path: String) throws -> ScanTree {
        try engine.scanBlocking(path).tree
    }

    @Test("Neue Datei: Ordner und alle Eltern wachsen um genau ihre belegte Größe")
    func growthPropagatesToRoot() throws {
        let fx = try Fixture()
        try fx.file("a/b/c/alt.bin", size: 10_000)
        try fx.file("a/geschwister/gross.bin", size: 3_000_000)
        try fx.file("z/x.bin", size: 2_000_000)
        let t0 = try fullScan(fx.root)
        expectValidTree(t0)
        let c = try #require(t0.index(ofPath: "a/b/c"))
        let chain = ["", "a", "a/b", "a/b/c"].map { t0.node(t0.index(ofPath: $0)!).allocatedSize }

        // Echte Datei (keine Sparse-Datei): 64 MB mit Inhalt.
        let neu = try fx.file("a/b/c/neu.bin", size: 64 << 20, byte: 0x5A)
        let grown = Fixture.allocated(neu)
        #expect(grown >= 64 << 20)

        let r = try engine.rescanBlocking(subtree: c, in: t0)
        let t1 = r.tree
        expectValidTree(t1)
        #expect(!r.removed)
        #expect(r.edit.allocatedDelta == Int64(grown))
        for (k, rel) in ["", "a", "a/b", "a/b/c"].enumerated() {
            let i = try #require(t1.index(ofPath: rel))
            #expect(t1.node(i).allocatedSize == chain[k] + grown, "\(rel)")
        }
        // Geschwister umsortiert: „a“ ist jetzt größer als „z“ (war es vorher schon),
        // und in a liegt „b“ jetzt vor „geschwister“.
        #expect(t1.root.child(named: "a")?.children.map(\.name) == ["b", "geschwister"])
        #expect(t0.root.child(named: "a")?.children.map(\.name) == ["geschwister", "b"])
        // Der alte Baum bleibt unverändert (copy-on-write).
        #expect(t0.node(c).allocatedSize == chain[3])
        expectValidTree(t0)
        // Vergleich mit einem frischen Scan.
        expectEquivalent(t1, try fullScan(fx.root))
        // Index des neu eingelesenen Knotens
        #expect(t1.path(of: r.edit.index) == fx.path("a/b/c"))
        #expect(t1.deadCount == 1) // alt.bin
        #expect(t1.liveCount == t1.count - 1)
    }

    @Test("Geschwister wandern beim Umsortieren; translate() folgt ihnen")
    func relocationTranslate() throws {
        let fx = try Fixture()
        for (i, n) in ["eins", "zwei", "drei", "vier"].enumerated() {
            try fx.file("\(n)/f.bin", size: (5 - i) * 100_000)
            try fx.file("\(n)/sub/g.bin", size: 1000)
        }
        let t0 = try fullScan(fx.root)
        #expect(t0.root.children.map(\.name) == ["eins", "zwei", "drei", "vier"])
        let vier = try #require(t0.index(ofPath: "vier"))
        let eins = try #require(t0.index(ofPath: "eins"))
        let einsSub = try #require(t0.index(ofPath: "eins/sub"))
        try fx.file("vier/riesig.bin", size: 2_000_000)
        let r = try engine.rescanBlocking(subtree: vier, in: t0)
        let t1 = r.tree
        expectValidTree(t1)
        #expect(t1.root.children.map(\.name) == ["vier", "eins", "zwei", "drei"])
        #expect(r.edit.index != vier)
        #expect(t1.name(of: r.edit.index) == "vier")
        #expect(r.edit.translate(vier) == r.edit.index)
        #expect(t1.name(of: try #require(r.edit.translate(eins))) == "eins")
        #expect(t1.path(of: try #require(r.edit.translate(einsSub))) == fx.path("eins/sub"))
        let oldChild = try #require(t0.index(ofPath: "vier/f.bin"))
        #expect(r.edit.translate(oldChild) == nil) // durch den Rescan ersetzt
        expectEquivalent(t1, try fullScan(fx.root))
    }

    @Test("Gelöschte Dateien: Größen sinken bis zur Wurzel, Ergebnis wie frischer Scan")
    func shrink() throws {
        let fx = try Fixture()
        for i in 0 ..< 20 { try fx.file("o/u\(i % 4)/f\(i).bin", size: 50_000 + i * 1000) }
        try fx.file("p/q.bin", size: 900_000)
        let t0 = try fullScan(fx.root)
        for i in 0 ..< 10 { unlink(fx.path("o/u\(i % 4)/f\(i).bin")) }
        rmdir(fx.path("o/u3")) // nicht leer → bleibt
        let r = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: "o")), in: t0)
        expectValidTree(r.tree)
        #expect(r.edit.allocatedDelta < 0)
        expectEquivalent(r.tree, try fullScan(fx.root))
        #expect(t0.root.children.map(\.name) == ["o", "p"])
        #expect(r.tree.root.children.map(\.name) == ["p", "o"])
    }

    @Test("Verschwundener Ordner wird beim Rescan entfernt")
    func vanishedOnRescan() throws {
        let fx = try Fixture()
        try fx.file("weg/a.bin", size: 100_000)
        try fx.file("bleibt/b.bin", size: 10_000)
        let t0 = try fullScan(fx.root)
        let weg = try #require(t0.index(ofPath: "weg"))
        try FileManager.default.removeItem(atPath: fx.path("weg"))
        let r = try engine.rescanBlocking(subtree: weg, in: t0)
        #expect(r.removed)
        expectValidTree(r.tree)
        #expect(r.tree.index(ofPath: "weg") == nil)
        #expect(r.edit.index == 0)
        expectEquivalent(r.tree, try fullScan(fx.root))
    }

    @Test("Rescan einer Datei und der Wurzel")
    func rescanFileAndRoot() throws {
        let fx = try Fixture()
        let f = try fx.file("d/datei.bin", size: 10_000)
        try fx.file("e.bin", size: 5000)
        let t0 = try fullScan(fx.root)
        try fx.file("d/datei.bin", size: 300_000)
        let r1 = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: f)), in: t0)
        expectValidTree(r1.tree)
        expectEquivalent(r1.tree, try fullScan(fx.root))
        try fx.file("neu/x.bin", size: 70_000)
        let r2 = try engine.rescanBlocking(subtree: 0, in: r1.tree)
        expectValidTree(r2.tree)
        #expect(r2.edit.compacted) // alle alten Knoten tot → über 25 %
        #expect(r2.tree.deadCount == 0)
        expectEquivalent(r2.tree, try fullScan(fx.root))
    }

    // MARK: Hardlinks

    @Test("Hardlink: neuer Link im Teilbaum mit größerem Pfad zählt als Duplikat")
    func hardlinkNewLinkLarger() throws {
        let fx = try Fixture()
        let orig = try fx.file("a/orig.bin", size: 500_000)
        try fx.hardlink(orig, "c/zweit.bin") // Gruppe ist beim Scan bekannt (nlink 2)
        try fx.dir("b")
        let t0 = try fullScan(fx.root)
        try fx.hardlink(orig, "b/link.bin")
        let r = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: "b")), in: t0)
        expectValidTree(r.tree)
        #expect(r.tree.root.allocatedSize == t0.root.allocatedSize)
        #expect(r.tree.root.child(named: "b")?.child(named: "link.bin")?.isHardlinkDuplicate == true)
        expectEquivalent(r.tree, try fullScan(fx.root))
    }

    @Test("Hardlink: neuer Link mit kleinerem Pfad übernimmt, der alte wird Duplikat")
    func hardlinkNewLinkSmaller() throws {
        let fx = try Fixture()
        let orig = try fx.file("z/orig.bin", size: 500_000)
        try fx.hardlink(orig, "zz/zweit.bin")
        try fx.dir("a")
        let t0 = try fullScan(fx.root)
        let one = Fixture.allocated(orig)
        try fx.hardlink(orig, "a/link.bin")
        let r = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: "a")), in: t0)
        let t1 = r.tree
        expectValidTree(t1)
        #expect(t1.root.allocatedSize == t0.root.allocatedSize)
        #expect(t1.root.child(named: "a")?.allocatedSize == one)
        #expect(t1.root.child(named: "z")?.allocatedSize == 0)
        #expect(t1.root.child(named: "z")?.child(named: "orig.bin")?.isHardlinkDuplicate == true)
        expectEquivalent(t1, try fullScan(fx.root))

        // Link im Teilbaum wieder löschen: z/orig.bin zählt wieder.
        unlink(fx.path("a/link.bin"))
        let r2 = try engine.rescanBlocking(subtree: try #require(t1.index(ofPath: "a")), in: t1)
        expectValidTree(r2.tree)
        #expect(r2.tree.root.child(named: "z")?.allocatedSize == one)
        #expect(r2.tree.root.child(named: "z")?.child(named: "orig.bin")?.isHardlinkDuplicate == false)
        expectEquivalent(r2.tree, try fullScan(fx.root))
    }

    @Test("Bekannte Grenze: Link auf eine beim Scan einfach verlinkte Datei")
    func hardlinkToFormerlySingleFile() throws {
        let fx = try Fixture()
        let orig = try fx.file("a/orig.bin", size: 500_000)
        try fx.dir("b")
        let t0 = try fullScan(fx.root)
        try fx.hardlink(orig, "b/link.bin")
        // a/orig.bin hatte beim Scan nlink 1 und steht nicht in der
        // Hardlink-Tabelle: Der Rescan von b allein zählt die Datei doppelt …
        let r = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: "b")), in: t0)
        expectValidTree(r.tree)
        #expect(r.tree.root.allocatedSize == 2 * t0.root.allocatedSize)
        // … der Rescan eines gemeinsamen Vorfahren stellt es richtig.
        let r2 = try engine.rescanBlocking(subtree: 0, in: r.tree)
        expectEquivalent(r2.tree, try fullScan(fx.root))
        #expect(r2.tree.root.allocatedSize == t0.root.allocatedSize)
    }

    @Test("Hardlink: Entfernen des gezählten Vorkommens gibt die Größe an das nächste")
    func hardlinkRemoveWinner() throws {
        let fx = try Fixture()
        let orig = try fx.file("a/orig.bin", size: 400_000)
        try fx.hardlink(orig, "b/zwei.bin")
        try fx.hardlink(orig, "c/drei.bin")
        let t0 = try fullScan(fx.root)
        let one = Fixture.allocated(orig)
        #expect(t0.root.child(named: "a")?.allocatedSize == one)
        let edit = t0.removingNode(at: try #require(t0.index(ofPath: "a/orig.bin")))
        expectValidTree(edit.tree)
        #expect(edit.tree.root.allocatedSize == t0.root.allocatedSize)
        #expect(edit.tree.root.child(named: "a")?.allocatedSize == 0)
        #expect(edit.tree.root.child(named: "b")?.allocatedSize == one)
        #expect(edit.tree.root.child(named: "b")?.child(named: "zwei.bin")?.isHardlinkDuplicate == false)
        #expect(edit.tree.name(of: edit.index) == "a")
        // Auf der Platte nachvollziehen und mit frischem Scan vergleichen.
        unlink(orig)
        expectEquivalent(edit.tree, try fullScan(fx.root))
    }

    @Test("Hardlinks innerhalb des Teilbaums und darüber hinaus (Rescan des Elternordners)")
    func hardlinkMixed() throws {
        let fx = try Fixture()
        let a = try fx.file("p/x/a.bin", size: 300_000)
        try fx.hardlink(a, "p/y/a2.bin")
        try fx.hardlink(a, "q/a3.bin")
        let t0 = try fullScan(fx.root)
        expectValidTree(t0)
        try fx.hardlink(a, "p/x/0-erst.bin") // kleinster Pfad überhaupt
        let r = try engine.rescanBlocking(subtree: try #require(t0.index(ofPath: "p")), in: t0)
        expectValidTree(r.tree)
        #expect(r.tree.root.allocatedSize == t0.root.allocatedSize)
        expectEquivalent(r.tree, try fullScan(fx.root))
    }

    // MARK: Entfernen, Undo, Kompaktierung

    @Test("removingNode propagiert die Größe; Undo per Rescan des Elternordners")
    func removeAndUndo() throws {
        let fx = try Fixture()
        try fx.file("ordner/weg/a.bin", size: 200_000)
        try fx.file("ordner/weg/b.bin", size: 100_000)
        try fx.file("ordner/rest.bin", size: 50_000)
        try fx.file("anderes/c.bin", size: 250_000)
        let t0 = try fullScan(fx.root)
        let weg = try #require(t0.index(ofPath: "ordner/weg"))
        let size = t0.node(weg).allocatedSize
        let rootBefore = t0.root.allocatedSize

        // „Papierkorb“: Ordner aus dem Fixture hinaus verschieben.
        let parking = try Fixture()
        #expect(rename(fx.path("ordner/weg"), parking.path("weg")) == 0)
        let edit = t0.removingNode(at: weg)
        let t1 = edit.tree
        expectValidTree(t1)
        #expect(edit.allocatedDelta == -Int64(size))
        #expect(t1.root.allocatedSize == rootBefore - size)
        #expect(t1.index(ofPath: "ordner/weg") == nil)
        #expect(t1.root.children.map(\.name) == ["anderes", "ordner"])
        #expect(t1.path(of: edit.index) == fx.path("ordner"))
        expectEquivalent(t1, try fullScan(fx.root))

        // Undo: zurückverschieben und den Elternordner neu einlesen.
        #expect(rename(parking.path("weg"), fx.path("ordner/weg")) == 0)
        let r = try engine.rescanBlocking(path: fx.path("ordner/weg"), in: t1)
        #expect(r.path == fx.path("ordner"))
        expectValidTree(r.tree)
        #expect(r.tree.root.allocatedSize == rootBefore)
        expectEquivalent(r.tree, try fullScan(fx.root))
    }

    @Test("Kompaktierung, sobald mehr als 25 % der Knoten tot sind")
    func compaction() throws {
        let fx = try Fixture()
        for i in 0 ..< 30 { try fx.file("gross/f\(i).bin", size: 1000 + i) }
        for i in 0 ..< 70 { try fx.file("rest/r\(i).bin", size: 2000 + i) }
        var tree = try fullScan(fx.root)
        let count0 = tree.count
        var compactedAt: Int?
        for round in 1 ... 3 {
            let g = try #require(tree.index(ofPath: "gross"))
            try fx.file("gross/runde\(round).bin", size: 500)
            let r = try engine.rescanBlocking(subtree: g, in: tree)
            expectValidTree(r.tree)
            expectEquivalent(r.tree, try fullScan(fx.root))
            if r.edit.compacted {
                compactedAt = round
                #expect(r.tree.deadCount == 0)
                #expect(r.tree.count == r.tree.liveCount)
                #expect(r.tree.path(of: r.edit.index) == fx.path("gross"))
            } else {
                #expect(!r.tree.needsCompaction)
                #expect(r.tree.deadCount > 0)
            }
            tree = r.tree
        }
        // 30 + 31 tote Knoten bei ~133 Knoten > 25 % → in Runde 2.
        #expect(compactedAt == 2, "Knoten anfangs \(count0)")

        // Ohne automatische Kompaktierung bleibt der Baum gültig; compacted() räumt auf.
        let g = try #require(tree.index(ofPath: "gross"))
        let sub = try fullScan(fx.path("gross"))
        let e1 = tree.replacingSubtree(at: g, with: sub, compactIfNeeded: false)
        let e2 = e1.tree.replacingSubtree(at: try #require(e1.translate(g)), with: sub, compactIfNeeded: false)
        #expect(e2.tree.needsCompaction)
        expectValidTree(e2.tree)
        let c = e2.tree.compacted()
        expectValidTree(c.tree)
        expectEquivalent(c.tree, e2.tree)
        let rest = try #require(e2.tree.index(ofPath: "rest"))
        let restNew = try #require(c.translate(rest))
        #expect(c.tree.name(of: restNew) == "rest")
    }

    @Test("Ein nicht betretener Einhängepunkt wird nicht neu eingelesen")
    func mountPointNotRescanned() throws {
        let t0 = try ScanEngine().scanBlocking("/System/Volumes").tree
        let data = try #require(t0.index(ofPath: "Data"))
        let r = try ScanEngine().rescanBlocking(subtree: data, in: t0)
        #expect(r.tree === t0)
        #expect(r.tree.node(data).childCount == 0)
    }

    @Test("Asynchroner Rescan")
    func asyncRescan() async throws {
        let fx = try Fixture()
        try fx.file("a/b.bin", size: 1000)
        let t0 = try fullScan(fx.root)
        try fx.file("a/c.bin", size: 100_000)
        let r = try await engine.rescan(subtree: try #require(t0.index(ofPath: "a")), in: t0)
        expectValidTree(r.tree)
        #expect(r.tree.root.fileCount == 2)
    }

    // MARK: Performance

    /// Synthetischer Baum: Wurzel → 100 Ordner → je 100 Ordner → je 200 Dateien
    /// (2 Mio. Dateien, 10 101 Ordner).
    static func syntheticTree(top: Int = 100, mid: Int = 100, files: Int = 200) throws -> ScanTree {
        var raw = RawTree()
        let total = 1 + top + top * mid + top * mid * files
        raw.reserve(total, nameBytes: total * 8)
        raw.append(parent: -1, name: Array("wurzel".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        var rng = SystemRandomNumberGenerator()
        for a in 0 ..< top {
            let ia = raw.append(parent: 0, name: Array("ordner\(a)".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
            for b in 0 ..< mid {
                let ib = raw.append(parent: ia, name: Array("unter\(b)".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
                for f in 0 ..< files {
                    let size = UInt64.random(in: 0 ..< 1_000_000, using: &rng) & ~4095
                    raw.append(parent: ib, name: Array("datei\(f).bin".utf8), flags: [], allocated: size,
                               logical: size, ownFiles: 1)
                }
            }
        }
        return try TreeBuilder.build(raw, rootPath: "/synthetisch/wurzel")
    }

    @Test("Performance: Einhängen eines kleinen Teilbaums in 2 Mio. Knoten unter 100 ms")
    func mergePerformance() throws {
        let big = try Self.syntheticTree()
        #expect(big.count > 2_000_000)
        var raw = RawTree()
        raw.append(parent: -1, name: Array("unter7".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        for f in 0 ..< 300 {
            raw.append(parent: 0, name: Array("neu\(f).bin".utf8), flags: [], allocated: 8192, logical: 8000, ownFiles: 1)
        }
        let sub = try TreeBuilder.build(raw, rootPath: "/synthetisch/wurzel/ordner42/unter7")
        let target = try #require(big.index(ofPath: "ordner42/unter7"))
        var best = Double.infinity
        var edit: TreeEdit?
        for _ in 0 ..< 3 {
            let start = DispatchTime.now().uptimeNanoseconds
            edit = big.replacingSubtree(at: target, with: sub)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let e = try #require(edit)
        #expect(best < 100, "Einhängen dauerte \(best) ms")
        #expect(e.tree.node(e.index).fileCount == 300)
        #expect(e.tree.root.fileCount == big.root.fileCount - 200 + 300)
        print("[perf] Teil-Rescan einhängen in \(big.count) Knoten: \(best) ms")
        expectValidTree(e.tree)
    }
}
