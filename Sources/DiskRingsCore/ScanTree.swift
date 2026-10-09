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
    /// Dateien mit `nlink > 1`, nach Knotenindex sortiert (für den Teil-Rescan).
    let hardlinks: [HardlinkEntry]
    /// `true`, wenn jede Datei ein eigener Knoten ist (fertiger Scan). Bei
    /// Live-Snapshots und Snapshots mit Mindestgröße stecken Dateien zum Teil
    /// nur in der Größe und Dateianzahl ihres Ordners.
    public let isComplete: Bool
    /// Anzahl toter Knoten (siehe `NodeFlags.dead`).
    public let deadCount: Int

    init(rootPath: String, nodes: [Node], names: [UInt8], hardlinks: [HardlinkEntry] = [],
         isComplete: Bool = true, deadCount: Int = 0) {
        precondition(!nodes.isEmpty, "Ein ScanTree hat immer eine Wurzel")
        self.rootPath = rootPath
        self.nodes = nodes
        self.names = names
        self.hardlinks = hardlinks
        self.isComplete = isComplete
        self.deadCount = deadCount
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

    /// Kinder sortiert nach dem Größenmodus. Bei `.allocated` ist das die
    /// gespeicherte Reihenfolge (`childIndices`). Bei `.logical`: logische
    /// Größe absteigend, dann belegte Größe absteigend, dann Name aufsteigend
    /// (UTF-8-Bytes). Kostet eine Sortierung der direkten Kinder.
    public func sortedChildIndices(of index: Int32, by mode: SizeMode) -> [Int32] {
        let range = childIndices(of: index)
        guard mode == .logical, range.count > 1 else { return Array(range) }
        return range.sorted { a, b in
            let na = nodes[Int(a)], nb = nodes[Int(b)]
            if na.logicalSize != nb.logicalSize { return na.logicalSize > nb.logicalSize }
            if na.allocatedSize != nb.allocatedSize { return na.allocatedSize > nb.allocatedSize }
            return nameBytes(of: a).lexicographicallyPrecedes(nameBytes(of: b))
        }
    }

    /// Anzahl aller Einträge unterhalb von `index` (ohne den Knoten selbst).
    public func itemCount(of index: Int32) -> Int {
        var count = 0
        var stack: [Int32] = [index]
        while let i = stack.popLast() {
            let n = nodes[Int(i)]
            count += Int(n.childCount)
            if n.childCount > 0 {
                for c in n.firstChild ..< n.firstChild + n.childCount where nodes[Int(c)].childCount > 0 {
                    stack.append(c)
                }
            }
        }
        return count
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
    ///
    /// Der Wurzelpfad passt nur an einer Komponentengrenze (`/a` passt nicht
    /// auf `/ab/c`). Namen werden zuerst bytegenau verglichen; findet sich so
    /// kein Kind, wird kanonisch äquivalent verglichen (NFC/NFD), damit eine
    /// Anfrage in anderer Unicode-Normalform als im Dateisystem trotzdem trifft.
    public func index(ofPath path: String) -> Int32? {
        let pathBytes = Array(path.utf8)
        let rootBytes = Array(rootPath.utf8)
        var rel: ArraySlice<UInt8>
        if pathBytes.starts(with: rootBytes) {
            rel = pathBytes[rootBytes.count...]
            // Nur an einer Komponentengrenze: danach muss „/“ kommen oder
            // nichts mehr (bei der Wurzel „/“ ist die Grenze schon erreicht).
            if rootBytes.last != UInt8(ascii: "/"), let first = rel.first, first != UInt8(ascii: "/") {
                return nil
            }
        } else if pathBytes.first == UInt8(ascii: "/") {
            // Wurzelpfad in anderer Normalform angefragt?
            guard let r = Self.stripRoot(path, rootPath) else { return nil }
            rel = ArraySlice(Array(r.utf8))
        } else {
            rel = pathBytes[...]
        }
        var current = Self.rootIndex
        for comp in rel.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true) {
            guard let hit = childIndex(of: current, nameBytes: comp) else { return nil }
            current = hit
        }
        return current
    }

    /// Kind von `index` mit dem gegebenen Namen: erst bytegenau, dann
    /// kanonisch äquivalent (NFC/NFD).
    public func childIndex<C: Collection>(of index: Int32, nameBytes want: C) -> Int32? where C.Element == UInt8 {
        let range = childIndices(of: index)
        if let hit = range.first(where: { nameBytes(of: $0).elementsEqual(want) }) { return hit }
        // ASCII-Namen haben nur eine Normalform; dann gibt es keinen Treffer.
        guard want.contains(where: { $0 >= 0x80 }) else { return nil }
        let wanted = String(decoding: want, as: UTF8.self)
        return range.first { name(of: $0) == wanted } // String-Vergleich = kanonische Äquivalenz
    }

    /// Entfernt den Wurzelpfad als Präfix, mit Unicode-äquivalentem Vergleich
    /// je Komponente. Gibt den Rest (relativ) zurück oder `nil`.
    static func stripRoot(_ path: String, _ root: String) -> String? {
        let p = path.split(separator: "/", omittingEmptySubsequences: true)
        let r = root.split(separator: "/", omittingEmptySubsequences: true)
        guard p.count >= r.count else { return nil }
        for (a, b) in zip(p, r) where a != b { return nil }
        return p.dropFirst(r.count).joined(separator: "/")
    }

    /// Speicherbedarf von Knoten-Array und Namenspuffer in Byte.
    public var memoryFootprint: Int {
        nodes.capacity * MemoryLayout<Node>.stride + names.capacity
    }

    /// Strukturgleichheit (Knoten, Namen und Wurzelpfad).
    public func isIdentical(to other: ScanTree) -> Bool {
        rootPath == other.rootPath && nodes == other.nodes && names == other.names
    }

    /// Anzahl der Ordner im Baum (inklusive Wurzel, falls Ordner; ohne tote Knoten).
    public var directoryCount: Int {
        nodes.reduce(0) { $0 + ($1.isDirectory && !$1.flags.contains(.dead) ? 1 : 0) }
    }

    /// Anzahl der lebenden Knoten (`count` minus tote Knoten).
    public var liveCount: Int { nodes.count - deadCount }

    /// Pfade aller lebenden Knoten mit dem gegebenen Flag (z. B. nicht lesbare Ordner).
    public func paths(withFlag flag: NodeFlags) -> [String] {
        nodes.indices.filter { nodes[$0].flags.contains(flag) && !nodes[$0].flags.contains(.dead) }
            .map { path(of: Int32($0)) }
    }

    /// Prüft die Invarianten des Baums und gibt die gefundenen Verstöße zurück
    /// (leer = in Ordnung, höchstens `limit` Meldungen):
    /// - Wurzel an Index 0 ohne Elternknoten; jeder lebende Knoten ist genau
    ///   einmal von der Wurzel aus erreichbar, tote Knoten nie, und ihre Anzahl
    ///   stimmt mit `deadCount` überein.
    /// - Kinder liegen zusammenhängend hinter dem Elternknoten, zeigen auf ihn
    ///   zurück und sind absteigend sortiert (belegt, logisch, Name).
    /// - Summen: Die belegte Größe eines Ordners ist mindestens die Summe seiner
    ///   Kinder (der Rest ist die Eigengröße des Ordners, z. B. auf ExFAT).
    ///   Logische Größe und Dateianzahl sind bei `isComplete` exakt die Summe,
    ///   sonst mindestens die Summe. Dateien haben keine Kinder und zählen 1.
    /// - Hardlink-Tabelle: sortiert, nur lebende Dateien; pro (Gerät, Inode)
    ///   zählt genau ein Vorkommen mit seiner echten Größe, die anderen mit 0.
    public func validate(limit: Int = 20) -> [String] {
        var problems: [String] = []
        func report(_ s: @autoclosure () -> String) {
            if problems.count < limit { problems.append(s()) }
        }
        let n = nodes.count
        if nodes[0].parent != -1 { report("Wurzel hat Elternknoten \(nodes[0].parent)") }
        if nodes[0].flags.contains(.dead) { report("Wurzel ist tot") }
        var reached = [Bool](repeating: false, count: n)
        reached[0] = true
        var reachedCount = 1
        var stack: [Int32] = [0]
        let comparator: (Node, Node) -> Bool = { a, b in
            self.names.withUnsafeBufferPointer { TreeBuilder.precedes(a, b, $0) }
        }
        while let i = stack.popLast() {
            let node = nodes[Int(i)]
            if !node.isDirectory {
                if node.childCount != 0 { report("Datei \(i) hat Kinder") }
                if isComplete, node.fileCount != 1 { report("Datei \(i) hat fileCount \(node.fileCount)") }
                continue
            }
            let r = childIndices(of: i)
            if node.childCount < 0 || (!r.isEmpty && (r.lowerBound <= i || Int(r.upperBound) > n)) {
                report("Ungültiger Kinderbereich \(r) bei \(i)")
                continue
            }
            var sumA: UInt64 = 0, sumL: UInt64 = 0, sumF: UInt64 = 0
            var prev: Node?
            for c in r {
                let child = nodes[Int(c)]
                if reached[Int(c)] { report("Knoten \(c) mehrfach erreichbar"); continue }
                reached[Int(c)] = true
                reachedCount += 1
                if child.flags.contains(.dead) { report("Toter Knoten \(c) ist Kind von \(i)") }
                if child.parent != i { report("Knoten \(c) zeigt auf Eltern \(child.parent) statt \(i)") }
                if let p = prev, !comparator(p, child) { report("Kinder von \(i) nicht sortiert bei \(c)") }
                prev = child
                sumA &+= child.allocatedSize
                sumL &+= child.logicalSize
                sumF &+= UInt64(child.fileCount)
                stack.append(c)
            }
            if node.allocatedSize < sumA { report("Ordner \(i): belegt \(node.allocatedSize) < Summe \(sumA)") }
            if isComplete {
                if node.logicalSize != sumL { report("Ordner \(i): logisch \(node.logicalSize) ≠ Summe \(sumL)") }
                if UInt64(node.fileCount) != sumF { report("Ordner \(i): Dateien \(node.fileCount) ≠ Summe \(sumF)") }
            } else {
                if node.logicalSize < sumL { report("Ordner \(i): logisch \(node.logicalSize) < Summe \(sumL)") }
                if UInt64(node.fileCount) < sumF { report("Ordner \(i): Dateien \(node.fileCount) < Summe \(sumF)") }
            }
        }
        var dead = 0
        for i in 0 ..< n {
            let isDead = nodes[i].flags.contains(.dead)
            if isDead { dead += 1 }
            if !isDead, !reached[i] { report("Lebender Knoten \(i) nicht erreichbar") }
        }
        if dead != deadCount { report("deadCount \(deadCount), tatsächlich \(dead)") }
        if reachedCount != n - dead { report("Erreichbar \(reachedCount), lebend \(n - dead)") }

        // Hardlink-Tabelle
        for (a, b) in zip(hardlinks, hardlinks.dropFirst()) where a.index >= b.index {
            report("Hardlink-Tabelle nicht sortiert bei \(b.index)")
        }
        var groups: [[UInt64]: [HardlinkEntry]] = [:]
        for h in hardlinks {
            guard h.index >= 0, Int(h.index) < n else { report("Hardlink-Index \(h.index) ungültig"); continue }
            let node = nodes[Int(h.index)]
            if node.flags.contains(.dead) || node.isDirectory { report("Hardlink \(h.index) tot oder Ordner") }
            groups[[UInt64(UInt32(bitPattern: h.dev)), h.ino], default: []].append(h)
        }
        for (_, members) in groups {
            let counted = members.filter { !nodes[Int($0.index)].flags.contains(.hardlinkDuplicate) }
            if counted.count != 1 { report("Hardlink-Gruppe mit \(counted.count) gezählten Vorkommen") }
            for m in members {
                let node = nodes[Int(m.index)]
                if node.flags.contains(.hardlinkDuplicate) {
                    if node.allocatedSize != 0 || node.logicalSize != 0 { report("Duplikat \(m.index) mit Größe") }
                } else if node.allocatedSize != m.allocated || node.logicalSize != m.logical {
                    report("Hardlink \(m.index): Größe \(node.allocatedSize) statt \(m.allocated)")
                }
            }
        }
        return problems
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
    /// Nur in der Cloud vorhanden (iCloud, `SF_DATALESS`); zählt mit 0 Byte.
    public var isDataless: Bool { node.flags.contains(.dataless) }
    /// Einhängepunkt eines anderen Volumes, der nicht betreten wurde.
    public var isMountPoint: Bool { node.flags.contains(.mountPoint) }
    /// Weiterer Hardlink auf eine schon gezählte Datei; zählt mit 0 Byte.
    public var isHardlinkDuplicate: Bool { node.flags.contains(.hardlinkDuplicate) }
    /// Anzahl aller Einträge (Dateien und Ordner) unterhalb des Knotens, ohne
    /// ihn selbst. Wird bei jedem Aufruf durch Ablaufen des Teilbaums
    /// berechnet (O(Teilbaum)); für Tooltips einmal pro Knoten abfragen.
    public var itemCount: Int { tree.itemCount(of: index) }
    /// Kinder in der Reihenfolge des Größenmodus (siehe
    /// `ScanTree.sortedChildIndices(of:by:)`).
    public func children(sortedBy mode: SizeMode) -> [NodeRef] {
        tree.sortedChildIndices(of: index, by: mode).map { NodeRef(tree: tree, index: $0) }
    }
    public var depth: Int { tree.depth(of: index) }
    public var childCount: Int { Int(node.childCount) }
    public var children: [NodeRef] { tree.childIndices(of: index).map { NodeRef(tree: tree, index: $0) } }
    public var parent: NodeRef? {
        let p = node.parent
        return p >= 0 ? NodeRef(tree: tree, index: p) : nil
    }

    /// Kind mit dem gegebenen Namen (lineare Suche; bytegenau, sonst
    /// kanonisch äquivalent, siehe `ScanTree.childIndex(of:nameBytes:)`).
    public func child(named name: String) -> NodeRef? {
        tree.childIndex(of: index, nameBytes: name.utf8).map { NodeRef(tree: tree, index: $0) }
    }

    public var description: String { "\(path) (\(allocatedSize) B)" }
}
