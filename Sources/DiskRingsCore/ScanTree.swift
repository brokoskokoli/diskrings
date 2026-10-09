/// Ergebnis eines Scans: kompaktes Knoten-Array plus Namenspuffer (SPEC 4.2).
///
/// Invarianten nach dem Aufbau:
/// - `nodes[0]` ist die Wurzel.
/// - Die Kinder jedes Knotens liegen zusammenhängend ab `firstChild` und sind
///   absteigend nach belegter Größe sortiert (bei Gleichstand: logische Größe
///   absteigend, dann Name aufsteigend nach UTF-8-Bytes).
/// - Eltern stehen immer vor ihren Kindern (Breitensuche-Reihenfolge).
/// - Ordnergrößen und `fileCount` sind die Summen ihres Teilbaums.
public final class ScanTree: Sendable {
    /// Absoluter, aufgelöster Pfad der Scan-Wurzel.
    public let rootPath: String
    public let nodes: [Node]
    public let names: [UInt8]

    init(rootPath: String, nodes: [Node], names: [UInt8]) {
        precondition(!nodes.isEmpty, "Ein ScanTree hat immer eine Wurzel")
        self.rootPath = rootPath
        self.nodes = nodes
        self.names = names
    }

    public static let rootIndex: Int32 = 0

    public var count: Int { nodes.count }
    public var root: NodeRef { NodeRef(tree: self, index: Self.rootIndex) }

    public subscript(index: Int32) -> NodeRef { NodeRef(tree: self, index: index) }

    public func node(_ index: Int32) -> Node { nodes[Int(index)] }

    public func nameBytes(of index: Int32) -> ArraySlice<UInt8> {
        let n = nodes[Int(index)]
        let start = Int(n.nameOffset)
        return names[start ..< start + Int(n.nameLength)]
    }

    public func name(of index: Int32) -> String {
        String(decoding: nameBytes(of: index), as: UTF8.self)
    }

    /// Indizes der Kinder (zusammenhängend, nach Größe absteigend).
    public func childIndices(of index: Int32) -> Range<Int32> {
        let n = nodes[Int(index)]
        return n.firstChild ..< n.firstChild + n.childCount
    }

    /// Tiefe unterhalb der Wurzel (Wurzel = 0).
    public func depth(of index: Int32) -> Int {
        var d = 0
        var i = nodes[Int(index)].parent
        while i >= 0 { d += 1; i = nodes[Int(i)].parent }
        return d
    }

    /// Rekonstruiert den absoluten Pfad über die Elternkette.
    public func path(of index: Int32) -> String {
        var parts: [Int32] = []
        var i = index
        while i > 0 { parts.append(i); i = nodes[Int(i)].parent }
        var bytes = Array(rootPath.utf8)
        for p in parts.reversed() {
            if bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: nameBytes(of: p))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Sucht einen Knoten über seinen absoluten Pfad (oder relativ zur Wurzel).
    public func index(ofPath path: String) -> Int32? {
        var rel = Substring(path)
        if rel.hasPrefix(rootPath) {
            rel = rel.dropFirst(rootPath.count)
        } else if rel.hasPrefix("/") {
            return nil
        }
        var current = Self.rootIndex
        for comp in rel.split(separator: "/", omittingEmptySubsequences: true) {
            let want = Array(comp.utf8)
            guard let hit = childIndices(of: current).first(where: { nameBytes(of: $0).elementsEqual(want) })
            else { return nil }
            current = hit
        }
        return current
    }

    /// Speicherbedarf von Knoten-Array und Namenspuffer in Byte.
    public var memoryFootprint: Int {
        nodes.capacity * MemoryLayout<Node>.stride + names.capacity
    }

    /// Strukturgleichheit (Knoten, Namen und Wurzelpfad).
    public func isIdentical(to other: ScanTree) -> Bool {
        rootPath == other.rootPath && nodes == other.nodes && names == other.names
    }

    /// Anzahl der Ordner im Baum (inklusive Wurzel, falls Ordner).
    public var directoryCount: Int { nodes.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) } }

    /// Pfade aller Knoten mit dem gegebenen Flag (z. B. nicht lesbare Ordner).
    public func paths(withFlag flag: NodeFlags) -> [String] {
        nodes.indices.filter { nodes[$0].flags.contains(flag) }.map { path(of: Int32($0)) }
    }
}

/// Leichter Lesezugriff auf einen Knoten.
public struct NodeRef: Sendable, Hashable, CustomStringConvertible {
    public let tree: ScanTree
    public let index: Int32

    public init(tree: ScanTree, index: Int32) {
        self.tree = tree
        self.index = index
    }

    public static func == (a: NodeRef, b: NodeRef) -> Bool { a.tree === b.tree && a.index == b.index }
    public func hash(into h: inout Hasher) {
        h.combine(ObjectIdentifier(tree))
        h.combine(index)
    }

    public var node: Node { tree.node(index) }
    public var name: String { tree.name(of: index) }
    public var path: String { tree.path(of: index) }
    public var allocatedSize: UInt64 { node.allocatedSize }
    public var logicalSize: UInt64 { node.logicalSize }
    public func size(_ mode: SizeMode) -> UInt64 { node.size(mode) }
    public var fileCount: Int { Int(node.fileCount) }
    public var flags: NodeFlags { node.flags }
    public var isDirectory: Bool { node.isDirectory }
    public var isPackage: Bool { node.flags.contains(.package) }
    public var isSymlink: Bool { node.flags.contains(.symlink) }
    public var isUnreadable: Bool { node.flags.contains(.unreadable) }
    public var depth: Int { tree.depth(of: index) }
    public var childCount: Int { Int(node.childCount) }
    public var children: [NodeRef] { tree.childIndices(of: index).map { NodeRef(tree: tree, index: $0) } }
    public var parent: NodeRef? {
        let p = node.parent
        return p >= 0 ? NodeRef(tree: tree, index: p) : nil
    }

    /// Kind mit dem gegebenen Namen (lineare Suche).
    public func child(named name: String) -> NodeRef? {
        let want = Array(name.utf8)
        return tree.childIndices(of: index)
            .first { tree.nameBytes(of: $0).elementsEqual(want) }
            .map { NodeRef(tree: tree, index: $0) }
    }

    public var description: String { "\(path) (\(allocatedSize) B)" }
}
