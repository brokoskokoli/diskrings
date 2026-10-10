@testable import DiskRingsCore
import Foundation
import Testing

let twoPi = 2 * Double.pi
let eps = 1e-9

/// root (1000)
///  ├─ a/ (600): a1/ (400: x 300, y 100), a2 200
///  ├─ b 300
///  ├─ c/ (100): 100 Dateien à 1
///  └─ leer/ (0)
func sampleTree() -> ScanTree {
    var b = ScanTreeBuilder(rootName: "r")
    let a = b.directory("a")
    let a1 = b.directory("a1", in: a)
    b.file("x", size: 300, in: a1)
    b.file("y", size: 100, in: a1)
    b.file("a2", size: 200, in: a)
    b.file("b", size: 300)
    let c = b.directory("c")
    for i in 0 ..< 100 { b.file("k\(i)", size: 1, in: c) }
    b.directory("leer")
    return b.build(rootPath: "/r")
}

func idx(_ t: ScanTree, _ path: String) -> Int32 { t.index(ofPath: path)! }

/// Prüft die Grundinvarianten eines Layouts.
func expectConsistent(_ l: SunburstLayout, _ t: ScanTree, sourceLocation: SourceLocation = #_sourceLocation) {
    let arcs = l.arcs
    // Ringbereiche lückenlos und nach Winkel sortiert.
    var expectedStart = 0
    for (k, r) in l.ringRanges.enumerated() {
        #expect(r.lowerBound == expectedStart, sourceLocation: sourceLocation)
        expectedStart = r.upperBound
        for i in r {
            #expect(arcs[i].depth == Int32(k + 1), sourceLocation: sourceLocation)
            #expect(arcs[i].startAngle <= arcs[i].endAngle + eps, sourceLocation: sourceLocation)
            if i > r.lowerBound {
                #expect(arcs[i].startAngle >= arcs[i - 1].endAngle - eps, sourceLocation: sourceLocation)
            }
        }
    }
    #expect(expectedStart == arcs.count, sourceLocation: sourceLocation)
    for (i, a) in arcs.enumerated() {
        #expect(a.startAngle >= -eps && a.endAngle <= twoPi + eps, sourceLocation: sourceLocation)
        if a.parentArc >= 0 {
            let p = arcs[Int(a.parentArc)]
            // Verschachtelung: Kind liegt im Winkelbereich des Eltern-Arcs, einen Ring weiter außen.
            #expect(a.startAngle >= p.startAngle - eps && a.endAngle <= p.endAngle + eps, sourceLocation: sourceLocation)
            #expect(a.depth == p.depth + 1, sourceLocation: sourceLocation)
            #expect(a.branch == p.branch, sourceLocation: sourceLocation)
            #expect(Int(a.parentArc) < i, sourceLocation: sourceLocation)
            if a.kind == .node { #expect(t.node(a.nodeIndex).parent == p.nodeIndex, sourceLocation: sourceLocation) }
        } else {
            #expect(a.depth == 1, sourceLocation: sourceLocation)
            #expect(Int(a.branch) == i, sourceLocation: sourceLocation)
        }
    }
    // Winkelsumme: Die Kinder füllen jeden Eltern-Arc genau aus.
    var childSum = [Int32: Double]()
    for a in arcs where a.parentArc >= 0 { childSum[a.parentArc, default: 0] += a.span }
    for (p, s) in childSum {
        #expect(abs(s - arcs[Int(p)].span) < 1e-7, sourceLocation: sourceLocation)
    }
}

@Suite("SunburstLayout")
struct SunburstLayoutTests {
    @Test("Ring 1 füllt den vollen Kreis, Winkel proportional zur Größe")
    func ringOneFullCircle() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t)
        expectConsistent(l, t)
        let ring1 = l.arcs(inRing: 1)
        #expect(ring1.map(\.kind) == [.node, .node, .node])
        #expect(ring1.map { t.name(of: $0.nodeIndex) } == ["a", "b", "c"])
        #expect(abs(ring1.reduce(0) { $0 + $1.span } - twoPi) < eps)
        #expect(abs(ring1[ring1.startIndex].span - twoPi * 0.6) < eps)
        #expect(ring1.first?.startAngle == 0)
        #expect(abs(ring1.last!.endAngle - twoPi) < eps)
        #expect(l.totalSize == 1000)
        #expect(l.focusSize == 1000)
    }

    @Test("Ordner mit Größe 0 erzeugt keinen Arc und keine Kinder")
    func zeroSizeFolder() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t)
        #expect(!l.arcs.contains { $0.kind == .node && $0.nodeIndex == idx(t, "leer") })
        // Fokus auf den leeren Ordner: leeres Layout.
        let empty = SunburstLayout(tree: t, focus: idx(t, "leer"))
        #expect(empty.isEmpty)
        #expect(empty.ringRanges.isEmpty)
        #expect(empty.totalSize == 0)
    }

    @Test("Leerer Baum und Datei als Fokus")
    func emptyCases() {
        let t = ScanTreeBuilder(rootName: "leer").build(rootPath: "/leer")
        #expect(SunburstLayout(tree: t).isEmpty)
        let s = sampleTree()
        let file = SunburstLayout(tree: s, focus: idx(s, "b"))
        #expect(file.isEmpty)
        #expect(file.focusSize == 300)
    }

    @Test("Kleine Elemente werden je Elternknoten zusammengefasst")
    func aggregation() {
        // c hat 100 Dateien à 1 Byte von 1000: je 0,36°, unter der Schwelle 0,5°.
        let t = sampleTree()
        let l = SunburstLayout(tree: t)
        let cArc = l.arcIndex(ofNode: idx(t, "c"))!
        let kids = l.arcs.filter { $0.parentArc == Int32(cArc) }
        #expect(kids.count == 1)
        #expect(kids[0].kind == .aggregate)
        #expect(kids[0].itemCount == 100)
        #expect(kids[0].size == 100)
        #expect(kids[0].nodeIndex == idx(t, "c"))
        #expect(abs(kids[0].span - l.arcs[cArc].span) < eps)
        // Mit Schwelle 0,3° erscheinen alle einzeln.
        let fine = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0.3))
        let cFine = fine.arcIndex(ofNode: idx(t, "c"))!
        let fineKids = fine.arcs.filter { $0.parentArc == Int32(cFine) }
        #expect(fineKids.count == 100)
        #expect(fineKids.allSatisfy { $0.kind == .node })
        expectConsistent(fine, t)
    }

    @Test("Schwelle trennt große und kleine Geschwister")
    func thresholdSplit() {
        var b = ScanTreeBuilder(rootName: "r")
        b.file("gross", size: 3590)
        b.file("grenze", size: 5) // genau 0,5°
        for i in 0 ..< 5 { b.file("klein\(i)", size: 1) }
        let t = b.build(rootPath: "/r")
        let l = SunburstLayout(tree: t)
        expectConsistent(l, t)
        #expect(l.arcs.map(\.kind) == [.node, .node, .aggregate])
        #expect(l.arcs[2].itemCount == 5)
        #expect(abs(l.arcs[1].span * 180 / .pi - 0.5) < 1e-9)
    }

    @Test("Ringanzahl begrenzt die Tiefe; Bereich 3–10")
    func ringLimit() {
        var b = ScanTreeBuilder(rootName: "r")
        var p: Int32 = 0
        for d in 0 ..< 15 { p = b.directory("d\(d)", in: p) }
        b.file("blatt", size: 100, in: p)
        let t = b.build(rootPath: "/r")
        for rings in [1, 3, 6, 10, 20] {
            let l = SunburstLayout(tree: t, options: SunburstOptions(maxRings: rings))
            let expected = min(max(rings, 3), 10)
            #expect(l.options.maxRings == expected)
            #expect(l.ringCount == expected)
            #expect(l.arcs.count == expected)
            expectConsistent(l, t)
        }
        var o = SunburstOptions()
        o.maxRings = 2
        #expect(o.maxRings == 3)
    }

    @Test("Fokus auf einen Unterordner")
    func subFocus() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t, focus: idx(t, "a"))
        expectConsistent(l, t)
        #expect(l.focusSize == 600)
        #expect(l.arcs(inRing: 1).map { t.name(of: $0.nodeIndex) } == ["a1", "a2"])
        #expect(l.arcs(inRing: 2).map { t.name(of: $0.nodeIndex) } == ["x", "y"])
        #expect(abs(l.arcs[0].span - twoPi * 400 / 600) < eps)
        // Unterhalb der Wurzel keine Volume-Segmente, auch wenn gesetzt.
        let u = SunburstLayout(tree: t, focus: idx(t, "a"), options: SunburstOptions(rootSegments: .unreadable(5000)))
        #expect(!u.arcs.contains { $0.kind.isVolumeSegment })
        #expect(u.totalSize == 600)
    }

    @Test("Systemdaten an der Volume-Wurzel, Teile im zweiten Ring")
    func systemSegment() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t, options: SunburstOptions(rootSegments: .unreadable(1000)))
        expectConsistent(l, t)
        #expect(l.totalSize == 2000)
        let ring1 = Array(l.arcs(inRing: 1))
        #expect(ring1.last?.kind == .system)
        #expect(ring1.last?.size == 1000)
        #expect(abs(ring1.last!.startAngle - .pi) < eps)
        #expect(abs(ring1.last!.endAngle - twoPi) < eps)
        // Die Kinder teilen sich die erste Hälfte.
        #expect(abs(ring1.dropLast().reduce(0) { $0 + $1.span } - .pi) < eps)
        // Der Teil liegt als letzter Arc im zweiten Ring.
        let part = l.arcs(inRing: 2).last!
        #expect(part.kind == .systemPart && part.part == 0 && part.size == 1000)
        #expect(l.systemPart(of: part)?.kind == .unreadable)
        // Auch eine leere Wurzel zeigt dann nur die Systemdaten.
        let e = ScanTreeBuilder(rootName: "e").build(rootPath: "/e")
        let le = SunburstLayout(tree: e, options: SunburstOptions(rootSegments: .unreadable(10)))
        #expect(le.arcs.map(\.kind) == [.system, .systemPart])
        #expect(abs(le.arcs[0].span - twoPi) < eps)
    }

    @Test("Systemdaten, löschbar und frei: Reihenfolge, Winkel, Prozent des ganzen Volumes")
    func allVolumeSegments() {
        let t = sampleTree() // 1000 Byte
        let s = RootSegments.full // System 300 + 200, löschbar 100, frei 400
        let l = SunburstLayout(tree: t, options: SunburstOptions(rootSegments: s))
        expectConsistent(l, t)
        #expect(l.totalSize == 2000)
        #expect(l.focusSize == 1000)
        let ring1 = Array(l.arcs(inRing: 1))
        #expect(ring1.suffix(3).map(\.kind) == [.system, .purgeable, .free])
        #expect(ring1.suffix(3).map(\.size) == [500, 100, 400])
        let free = ring1.last!
        #expect(abs(free.span - twoPi * 0.2) < eps)
        #expect(abs(free.endAngle - twoPi) < eps)
        let parts = l.arcs(inRing: 2).filter { $0.kind == .systemPart }
        #expect(parts.map(\.size) == [300, 200])
        #expect(parts.map { l.volumeSegmentTitle($0) } == ["V", L("arc.unreadableSystem.title")])
        #expect(l.volumeSegmentTitle(free) == L("arc.free.title"))
        #expect(l.volumeSegmentTitle(ring1[0]) == nil)
        #expect(l.volumeSegmentDetail(parts[1], fullDiskAccessDenied: true)!.count
            > l.volumeSegmentDetail(parts[1], fullDiskAccessDenied: false)!.count)
        // Ohne Teile im zweiten Ring bleiben die Ordner unverändert nach Winkel sortiert.
        let without = SunburstLayout(tree: t, options: SunburstOptions(rootSegments: RootSegments(free: 1000)))
        expectConsistent(without, t)
        #expect(without.arcs(inRing: 1).last?.kind == .free)
        #expect(!without.arcs.contains { $0.kind == .system || $0.kind == .systemPart })
        // Logischer Modus und unter der Wurzel: keine Segmente (App setzt sie nur im Modus „belegt“).
        let sub = SunburstLayout(tree: t, focus: idx(t, "a"), options: SunburstOptions(rootSegments: s))
        #expect(!sub.arcs.contains { $0.kind.isVolumeSegment })
        #expect(abs(SunburstLayout.angularSpan(of: idx(t, "a"), under: 0, tree: t,
                                               options: SunburstOptions(rootSegments: s))!.end - twoPi * 0.3) < eps)
    }

    @Test("Restgröße eines Ordners (Live-Snapshot) wird als eigenes Segment gezeigt")
    func remainder() {
        var b = ScanTreeBuilder(rootName: "r")
        let d = b.partialDirectory("d", ownSize: 500, files: 10)
        b.partialDirectory("sub2", ownSize: 500, files: 3, in: d)
        let t = b.build(rootPath: "/r")
        let l = SunburstLayout(tree: t)
        expectConsistent(l, t)
        let ring2 = Array(l.arcs(inRing: 2))
        #expect(ring2.map(\.kind) == [.node, .remainder])
        #expect(ring2[1].size == 500)
        #expect(abs(ring2[1].span - .pi) < eps)
    }

    @Test("Eigengröße plus übrige Kinder ergibt ein Sammelsegment (Rest = Elterngröße − platzierte)")
    func remainderWithRestChildren() {
        var b = ScanTreeBuilder(rootName: "r")
        let d = b.partialDirectory("d", ownSize: 500, files: 10)
        b.partialDirectory("gross", ownSize: 1000, files: 3, in: d)
        b.file("winzig", size: 1, in: d)
        let t = b.build(rootPath: "/r")
        let l = SunburstLayout(tree: t)
        expectConsistent(l, t)
        let ring2 = Array(l.arcs(inRing: 2))
        #expect(ring2.map(\.kind) == [.node, .aggregate])
        #expect(ring2[1].size == 501)
        #expect(ring2[1].itemCount == 1)
    }

    @Test("Kinder mit Größe 0 erzeugen keine Arcs, auch ohne Schwelle")
    func zeroSizeChildren() {
        var b = ScanTreeBuilder(rootName: "r")
        b.file("voll", size: 100)
        b.directory("leer1")
        b.directory("leer2")
        b.file("null", size: 0)
        let t = b.build(rootPath: "/r")
        for mode in SizeMode.allCases {
            let l = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, sizeMode: mode))
            #expect(l.arcs.count == 1)
            #expect(l.arcs.allSatisfy { $0.size > 0 && $0.span > 0 })
        }
    }

    @Test("Schwelle: genau an der Grenze einzeln, knapp darunter im Sammelsegment")
    func thresholdBoundary() {
        // Gesamt 36 000 → 1 Byte = 0,01°; 50 Byte = genau 0,5°, 49 Byte = 0,49°.
        var b = ScanTreeBuilder(rootName: "r")
        b.file("gross", size: 35_901)
        b.file("genau", size: 50)
        b.file("knapp", size: 49)
        let t = b.build(rootPath: "/r")
        let l = SunburstLayout(tree: t)
        #expect(l.arcs.map(\.kind) == [.node, .node, .aggregate])
        #expect(t.name(of: l.arcs[1].nodeIndex) == "genau")
        #expect(l.arcs[2].size == 49)
        // Schwelle 0,49°: jetzt auch „knapp“ einzeln (>=, nicht >).
        let l2 = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0.49))
        #expect(l2.arcs.map(\.kind) == [.node, .node, .node])
    }

    @Test("Obergrenze wird nie überschritten (auch mit Restsegment und „Nicht zugeordnet“)")
    func arcCapNeverExceeded() {
        var b = ScanTreeBuilder(rootName: "r")
        for i in 0 ..< 6 {
            let d = b.partialDirectory("d\(i)", ownSize: 50, files: 1)
            for j in 0 ..< 5 { b.file("f\(j)", size: 10, in: d) }
        }
        let t = b.build(rootPath: "/r")
        for maxArcs in 1 ... 40 {
            for unassigned: UInt64 in [0, 300] {
                let l = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, maxArcs: maxArcs,
                                                                         rootSegments: .unreadable(unassigned)))
                #expect(l.arcs.count <= maxArcs, "maxArcs \(maxArcs), unassigned \(unassigned): \(l.arcs.count)")
                expectConsistent(l, t)
            }
        }
        let demo = DemoTree.home()
        for maxArcs in [1, 2, 5, 50, 500] {
            #expect(SunburstLayout(tree: demo, options: SunburstOptions(minAngleDegrees: 0, maxArcs: maxArcs,
                                                                        rootSegments: .full)).arcs.count <= maxArcs)
        }
    }

    @Test("Inkonsistenter Baum (Kindersumme > Eltern): Kinder bleiben im Eltern-Arc")
    func inconsistentTreeClamped() {
        // Direkt gebaut, weil TreeBuilder/ScanTreeBuilder immer konsistente Summen erzeugen.
        func node(_ size: UInt64, parent: Int32, first: Int32, count: Int32, name: UInt32, dir: Bool) -> Node {
            Node(allocatedSize: size, logicalSize: size, parent: parent, firstChild: first, childCount: count,
                 nameOffset: name, fileCount: 1, nameLength: 1, flags: dir ? .directory : [])
        }
        let nodes = [
            node(100, parent: -1, first: 1, count: 2, name: 0, dir: true), // Wurzel: 100
            node(80, parent: 0, first: 3, count: 1, name: 1, dir: true), // a: 80, Kind 200 (!)
            node(60, parent: 0, first: 4, count: 0, name: 2, dir: false), // b: 60 → Summe 140 > 100
            node(200, parent: 1, first: 4, count: 0, name: 3, dir: false),
        ]
        let t = ScanTree(rootPath: "/x", nodes: nodes, names: Array("rabc".utf8))
        let l = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0))
        expectConsistent(l, t)
        #expect(l.arcs.allSatisfy { $0.startAngle >= 0 && $0.endAngle <= twoPi + 1e-12 })
        let ring1 = Array(l.arcs(inRing: 1))
        #expect(ring1.count == 2)
        #expect(abs(ring1[1].endAngle - twoPi) < 1e-12)
        #expect(ring1[1].size == 20)
        let ring2 = Array(l.arcs(inRing: 2))
        #expect(ring2.count == 1)
        #expect(abs(ring2[0].endAngle - ring1[0].endAngle) < 1e-12)
    }

    @Test("Obergrenze für die Zahl der Arcs")
    func arcCap() {
        var b = ScanTreeBuilder(rootName: "r")
        for i in 0 ..< 50 {
            let d = b.directory("d\(i)")
            for j in 0 ..< 20 { b.file("f\(j)", size: 100, in: d) }
        }
        let t = b.build(rootPath: "/r")
        // Ohne Schwelle: 50 + 1000 Arcs.
        let all = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0))
        #expect(all.arcs.count == 1050)
        // Grenze 500: Ring 2 würde sie sprengen und entfällt ganz.
        let capped = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, maxArcs: 500))
        #expect(capped.arcs.count == 50)
        #expect(capped.ringCount == 1)
        expectConsistent(capped, t)
        // Grenze 10: Ring 1 wird gekürzt, der Rest landet im Sammelsegment.
        let tiny = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, maxArcs: 10))
        #expect(tiny.arcs.count == 10)
        #expect(tiny.arcs.last?.kind == .aggregate)
        #expect(tiny.arcs.last?.itemCount == 41)
        #expect(abs(tiny.arcs.reduce(0) { $0 + $1.span } - twoPi) < eps)
        expectConsistent(tiny, t)
        // Grenze 1 mit „Nicht zugeordnet“: nur das Sammelsegment und das Spezialsegment passen nicht beide;
        // das Spezialsegment bleibt immer erhalten.
        let two = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, maxArcs: 2, rootSegments: .unreadable(100)))
        #expect(two.arcs.map(\.kind) == [.aggregate, .system])
        let one = SunburstLayout(tree: t, options: SunburstOptions(minAngleDegrees: 0, maxArcs: 1, rootSegments: .unreadable(100)))
        #expect(one.arcs.map(\.kind) == [.system])
    }

    @Test("Logische Größe: eigene Reihenfolge und Winkel")
    func logicalMode() {
        var b = ScanTreeBuilder(rootName: "r")
        b.file("sparse", size: 4096, logical: 1_000_000)
        b.file("dicht", size: 800_000, logical: 800_000)
        b.file("klein", size: 100_000, logical: 100)
        let t = b.build(rootPath: "/r")
        let alloc = SunburstLayout(tree: t)
        #expect(alloc.arcs.map { t.name(of: $0.nodeIndex) }.prefix(2) == ["dicht", "klein"])
        let logical = SunburstLayout(tree: t, options: SunburstOptions(sizeMode: .logical))
        expectConsistent(logical, t)
        #expect(logical.arcs.prefix(2).map { t.name(of: $0.nodeIndex) } == ["sparse", "dicht"])
        #expect(logical.totalSize == 1_800_100)
        #expect(logical.arcs.last?.kind == .aggregate)
    }

    @Test("Demo-Baum: Invarianten über alle Ringzahlen und Fokusknoten")
    func demoInvariants() {
        let t = DemoTree.home()
        for rings in [3, 6, 10] {
            let l = SunburstLayout(tree: t, options: SunburstOptions(maxRings: rings, rootSegments: .unreadable(30_000_000_000)))
            expectConsistent(l, t)
            #expect(l.ringCount <= rings)
        }
        for path in ["Library", "Library/Caches", "Pictures/Photos Library.photoslibrary", "Leer"] {
            let l = SunburstLayout(tree: t, focus: idx(t, path))
            expectConsistent(l, t)
        }
    }

    @Test("Winkelbereich eines Knotens im Raum eines Vorfahren")
    func angularSpan() throws {
        let t = sampleTree()
        let o = SunburstOptions()
        let a1 = idx(t, "a/a1")
        let s = try #require(SunburstLayout.angularSpan(of: a1, under: 0, tree: t, options: o))
        #expect(s.depth == 2)
        #expect(abs(s.start) < eps)
        #expect(abs(s.end - twoPi * 0.4) < eps)
        // Stimmt mit dem Arc im Layout überein.
        let l = SunburstLayout(tree: t)
        let arc = l.arcs[l.arcIndex(ofNode: a1)!]
        #expect(abs(arc.startAngle - s.start) < eps && abs(arc.endAngle - s.end) < eps)
        let y = try #require(SunburstLayout.angularSpan(of: idx(t, "a/a1/y"), under: idx(t, "a"), tree: t, options: o))
        #expect(abs(y.start - twoPi * 300 / 600) < eps)
        #expect(abs(y.end - twoPi * 400 / 600) < eps)
        #expect(y.depth == 2)
        #expect(SunburstLayout.angularSpan(of: idx(t, "b"), under: idx(t, "a"), tree: t, options: o) == nil)
        let selfSpan = try #require(SunburstLayout.angularSpan(of: 0, under: 0, tree: t, options: o))
        #expect(selfSpan.depth == 0 && abs(selfSpan.end - twoPi) < eps)
        // Mit „Nicht zugeordnet“ schrumpft der Bereich entsprechend.
        let u = try #require(SunburstLayout.angularSpan(of: idx(t, "b"), under: 0, tree: t,
                                                        options: SunburstOptions(rootSegments: .unreadable(1000))))
        #expect(abs(u.start - twoPi * 600 / 2000) < eps)
        #expect(abs(u.end - twoPi * 900 / 2000) < eps)
    }
}

@Suite("ScanTreeBuilder und DemoTree")
struct ScanTreeBuilderTests {
    @Test("Summen, Sortierung und Pfade")
    func builder() {
        let t = sampleTree()
        #expect(t.root.allocatedSize == 1000)
        #expect(t.root.fileCount == 104)
        #expect(t.root.children.map(\.name) == ["a", "b", "c", "leer"])
        #expect(t[idx(t, "a/a1/x")].path == "/r/a/a1/x")
        #expect(t[idx(t, "leer")].isDirectory)
        expectValidTree(t)
    }

    @Test("Demo-Baum ist deterministisch")
    func demoDeterministic() {
        let a = DemoTree.home(), b = DemoTree.home()
        #expect(a.isIdentical(to: b))
        #expect(a.count > 1000)
        #expect(a.root.allocatedSize > 100_000_000_000)
        expectValidTree(a)
        let big = DemoTree.large(nodeCount: 5000)
        #expect(big.count == 5000)
        expectValidTree(big)
    }
}
