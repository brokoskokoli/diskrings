@testable import DiskRingsCore
import Testing

@Suite("ScanTree und TreeBuilder")
struct ScanTreeTests {
    /// root
    ///  ├─ a/ (x 100, y 300)
    ///  ├─ b 500
    ///  └─ c/ (leer)
    func sample() throws -> ScanTree {
        var raw = RawTree()
        raw.append(parent: -1, name: Array("wurzel".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        let c = raw.append(parent: 0, name: Array("c".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        let a = raw.append(parent: 0, name: Array("a".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        raw.append(parent: a, name: Array("x".utf8), flags: [], allocated: 100, logical: 90, ownFiles: 1)
        raw.append(parent: 0, name: Array("b".utf8), flags: [], allocated: 500, logical: 480, ownFiles: 1)
        raw.append(parent: a, name: Array("y".utf8), flags: [], allocated: 300, logical: 10, ownFiles: 1)
        _ = c
        return try TreeBuilder.build(raw, rootPath: "/tmp/wurzel")
    }

    @Test("Knoten sind 40 Byte groß")
    func nodeSize() {
        #expect(MemoryLayout<Node>.size == 40)
        #expect(MemoryLayout<Node>.stride == 40)
    }

    @Test("Summen werden nach oben propagiert")
    func sums() throws {
        let t = try sample()
        #expect(t.root.allocatedSize == 900)
        #expect(t.root.logicalSize == 580)
        #expect(t.root.fileCount == 3)
        #expect(t.root.child(named: "a")?.allocatedSize == 400)
        #expect(t.root.child(named: "a")?.fileCount == 2)
        #expect(t.root.child(named: "c")?.allocatedSize == 0)
        expectValidTree(t)
    }

    @Test("Kinder absteigend sortiert und zusammenhängend")
    func sorting() throws {
        let t = try sample()
        #expect(t.root.children.map(\.name) == ["b", "a", "c"])
        #expect(t.root.child(named: "a")?.children.map(\.name) == ["y", "x"])
        // Breitensuche: Wurzel, dann ihre drei Kinder direkt dahinter.
        #expect(t.root.node.firstChild == 1)
        #expect(t.root.node.childCount == 3)
    }

    @Test("Gleich große Geschwister werden nach Name sortiert")
    func tieBreak() throws {
        var raw = RawTree()
        raw.append(parent: -1, name: Array("r".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        for n in ["zeta", "alpha", "mu", "Beta"] {
            raw.append(parent: 0, name: Array(n.utf8), flags: [], allocated: 4096, logical: 10, ownFiles: 1)
        }
        let t = try TreeBuilder.build(raw, rootPath: "/r")
        #expect(t.root.children.map(\.name) == ["Beta", "alpha", "mu", "zeta"])
    }

    @Test("Pfade werden über die Elternkette rekonstruiert")
    func paths() throws {
        let t = try sample()
        let y = try #require(t.root.child(named: "a")?.child(named: "y"))
        #expect(y.path == "/tmp/wurzel/a/y")
        #expect(y.parent?.name == "a")
        #expect(y.depth == 2)
        #expect(t.root.path == "/tmp/wurzel")
        #expect(t.root.parent == nil)
        #expect(t.index(ofPath: "/tmp/wurzel/a/y") == y.index)
        #expect(t.index(ofPath: "a/x") != nil)
        #expect(t.index(ofPath: "/tmp/wurzel") == 0)
        #expect(t.index(ofPath: "/tmp/wurzel/gibtsnicht") == nil)
        #expect(t.index(ofPath: "/anderswo/a") == nil)
    }

    @Test("Wurzel „/“ ergibt Pfade ohne doppelten Schrägstrich")
    func slashRoot() throws {
        var raw = RawTree()
        raw.append(parent: -1, name: Array("/".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        raw.append(parent: 0, name: Array("Users".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        let t = try TreeBuilder.build(raw, rootPath: "/")
        #expect(t.root.children.first?.path == "/Users")
    }

    @Test("Abbruch während des Aufbaus")
    func cancelBuild() {
        #expect(throws: TreeBuildError.self) {
            var raw = RawTree()
            raw.append(parent: -1, name: [0x72], flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
            return try TreeBuilder.build(raw, rootPath: "/r") { true }
        }
    }

    @Test("NodeRef ist hashbar und vergleicht Baum und Index")
    func nodeRefIdentity() throws {
        let t = try sample()
        let t2 = try sample()
        #expect(t.root == t.root)
        #expect(t.root != t2.root)
        #expect(Set([t.root, t.root, t[1]]).count == 2)
        #expect(t.isIdentical(to: t2))
    }
}

@Suite("MappedBuffer")
struct MappedBufferTests {
    @Test("Wachsen, Lesen, Schreiben und Kopieren")
    func growAndCopy() {
        var b = MappedBuffer<UInt64>()
        let wasEmpty = b.isEmpty
        #expect(wasEmpty)
        for i in 0 ..< 100_000 { b.append(UInt64(i) * 3) }
        let (count, capacity, last) = (b.count, b.capacity, b[99_999])
        #expect(count == 100_000)
        #expect(capacity >= 100_000)
        #expect(last == 299_997)
        b[5] = 42
        let c = b.copy()
        b[5] = 7
        let copied = c.toArray()
        #expect(copied[5] == 42)
        #expect(copied.count == 100_000)
        #expect(copied.prefix(3) == [0, 3, 6])
        #expect(b.toArray()[5] == 7)
    }

    @Test("Genullt angelegt und Anhängen ganzer Puffer")
    func zeroedAndAppend() {
        let z = MappedBuffer<Int32>(zeroedCount: 10_000).toArray()
        #expect(z.count == 10_000)
        #expect(z.allSatisfy { $0 == 0 })
        var a = MappedBuffer<UInt8>()
        let bytes: [UInt8] = Array("hallo".utf8)
        bytes.withUnsafeBufferPointer { a.append(contentsOf: $0) }
        let b = a.copy()
        a.append(contentsOf: b)
        let text = String(decoding: a.toArray(), as: UTF8.self)
        #expect(text == "hallohallo")
    }

    @Test("Speicherbedarf des Baums: 40 Byte pro Knoten plus Namen")
    func treeFootprint() throws {
        var raw = RawTree()
        raw.append(parent: -1, name: Array("wurzel".utf8), flags: .directory, allocated: 0, logical: 0, ownFiles: 0)
        raw.append(parent: 0, name: Array("abc".utf8), flags: [], allocated: 1, logical: 1, ownFiles: 1)
        let t = try TreeBuilder.build(raw, rootPath: "/w")
        #expect(t.names.count == 9)
        #expect(t.memoryFootprint >= 2 * 40 + 9)
    }
}
