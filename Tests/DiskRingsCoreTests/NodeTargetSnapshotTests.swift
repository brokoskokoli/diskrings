@testable import DiskRingsCore
import Foundation
import Testing

/// Ziele eines Kontextmenüs werden über Pfad und Art festgehalten und vor
/// der Ausführung im aktuellen Baum neu aufgelöst. Ein Teil-Rescan, der
/// während das Menü offen ist fertig wird, kann Knoten umnummerieren; dann
/// darf der alte Index nie ein anderes Element treffen.
@Suite("Kontextmenü: Ziele über Pfade festhalten und neu auflösen")
struct NodeTargetSnapshotTests {
    @Test("Unveränderter Baum: dieselben Indizes")
    func unchanged() throws {
        let tree = smallTree()
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        let snap = NodeTargetSnapshot(nodes: [film, caches], in: tree)
        #expect(snap.resolve(in: tree) == [film, caches])
        #expect(snap.entries.map(\.kind) == [.file, .directory])
        #expect(snap.entries.map(\.path) == ["/Users/demo/Movies/film.mov", "/Users/demo/Library/Caches"])
    }

    @Test("Kompaktierung nummeriert um: dieselben Pfade lösen auf die neuen Indizes auf")
    func compaction() throws {
        var b = ScanTreeBuilder(rootName: "r")
        for i in 0 ..< 40 { b.file("f\(i)", size: UInt64(1000 + i)) }
        let tree = b.build(rootPath: "/r")
        let keep = try #require(tree.index(ofPath: "f0"))
        let snap = NodeTargetSnapshot(nodes: [keep], in: tree)
        let chain = tree.removingNodes((10 ..< 40).compactMap { tree.index(ofPath: "f\($0)") })
        #expect(chain.edits.contains { $0.compacted })
        let newTree = chain.tree
        // Der alte Index zeigt jetzt auf etwas anderes (oder ins Leere) …
        #expect(Int(keep) >= newTree.count || newTree.name(of: keep) != "f0")
        // … aufgelöst wird über den Pfad.
        let resolved = try #require(snap.resolve(in: newTree))
        #expect(resolved.map { newTree.name(of: $0) } == ["f0"])
    }

    @Test("Ziel inzwischen entfernt → keine Auflösung (nichts wird ausgeführt)")
    func removed() throws {
        let tree = smallTree()
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let notiz = try #require(tree.index(ofPath: "notiz.txt"))
        let snap = NodeTargetSnapshot(nodes: [notiz, film], in: tree)
        let newTree = tree.removingNodes([film]).tree
        #expect(snap.resolve(in: newTree) == nil)
        #expect(snap.resolve(in: nil) == nil)
    }

    @Test("Pfad bezeichnet jetzt eine andere Art (Datei → Ordner, Ordner → Symlink) → keine Auflösung")
    func kindChanged() throws {
        var b1 = ScanTreeBuilder(rootName: "demo")
        b1.file("x", size: 10)
        b1.directory("d")
        let t1 = b1.build(rootPath: "/demo")
        var b2 = ScanTreeBuilder(rootName: "demo")
        b2.directory("x")
        b2.file("d", size: 10, flags: .symlink)
        let t2 = b2.build(rootPath: "/demo")
        let x = try #require(t1.index(ofPath: "x"))
        let d = try #require(t1.index(ofPath: "d"))
        #expect(NodeTargetSnapshot(nodes: [x], in: t1).resolve(in: t2) == nil)
        #expect(NodeTargetSnapshot(nodes: [d], in: t1).resolve(in: t2) == nil)
        #expect(NodeTargetSnapshot(nodes: [x], in: t1).resolve(in: t1) == [x])
    }

    @Test("Ungültige oder tote Indizes beim Festhalten, andere Scan-Wurzel → keine Auflösung")
    func invalid() throws {
        let tree = smallTree()
        #expect(NodeTargetSnapshot(nodes: [-1], in: tree).resolve(in: tree) == nil)
        #expect(NodeTargetSnapshot(nodes: [9999], in: tree).resolve(in: tree) == nil)
        #expect(NodeTargetSnapshot(nodes: [], in: tree).resolve(in: tree) == nil)
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let removed = tree.removingNodes([film], compactIfNeeded: false).tree
        #expect(NodeTargetSnapshot(nodes: [film], in: removed).resolve(in: removed) == nil)
        let other = smallTree(rootPath: "/Users/other")
        #expect(NodeTargetSnapshot(nodes: [film], in: tree).resolve(in: other) == nil)
    }

    @Test("Unicode: Pfad in anderer Normalform trifft nicht stillschweigend ein anderes Element")
    func unicodeExact() throws {
        var b = ScanTreeBuilder(rootName: "u")
        b.file("Gr\u{00FC}n.txt", size: 10)
        let tree = b.build(rootPath: "/u")
        let n = try #require(tree.index(ofPath: "Gr\u{00FC}n.txt"))
        #expect(NodeTargetSnapshot(nodes: [n], in: tree).resolve(in: tree) == [n])
    }

    @Test("Vergleich: Einträge über Pfade festhalten, nach Neuberechnung des Vergleichs neu auflösen")
    func compareEntries() throws {
        func snap(_ t: ScanTree) -> Snapshot { Snapshot(metadata: SnapshotMetadata(rootPath: t.rootPath), tree: t) }
        var b = ScanTreeBuilder(rootName: "demo")
        b.file("a", size: 100)
        b.file("b", size: 200)
        let old = b.build(rootPath: "/demo")
        let d1 = SnapshotDiff(old: snap(old), new: snap(old))
        let eb = try #require(d1.entry(forPath: "/demo/b"))
        let target = CompareTargetSnapshot(entries: [eb], in: d1)
        #expect(target.resolve(in: d1) == [eb])
        // Neuer Vergleich, in dem „a“ wächst und eine neue Datei vor „b“ einsortiert wird.
        var b2 = ScanTreeBuilder(rootName: "demo")
        b2.file("a", size: 900)
        b2.file("aa", size: 500)
        b2.file("b", size: 200)
        let d2 = SnapshotDiff(old: snap(old), new: snap(b2.build(rootPath: "/demo")))
        let resolved = try #require(target.resolve(in: d2))
        #expect(resolved.map { d2.path(of: $0) } == ["/demo/b"])
        // Entfernt bzw. andere Art → nil.
        var b3 = ScanTreeBuilder(rootName: "demo")
        b3.file("a", size: 100)
        b3.directory("b")
        let d3 = SnapshotDiff(old: snap(b3.build(rootPath: "/demo")), new: snap(b3.build(rootPath: "/demo")))
        #expect(target.resolve(in: d3) == nil)
        #expect(target.resolve(in: nil) == nil)
        #expect(CompareTargetSnapshot(entries: [999], in: d1).resolve(in: d1) == nil)
    }
}
