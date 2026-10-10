import Darwin

/// Unsortierter Rohbaum in Spaltenform (structure of arrays), wie ihn der
/// Scanner bzw. die Live-Snapshots liefern. Knoten 0 ist die Wurzel; die
/// Eltern dürfen in beliebiger Reihenfolge stehen.
struct RawTree: ~Copyable {
    var parent = MappedBuffer<Int32>()
    var nameOffset = MappedBuffer<UInt32>()
    var nameLength = MappedBuffer<UInt16>()
    var flags = MappedBuffer<UInt16>()
    /// Eigene Größe des Knotens (bei Ordnern in der Regel 0, bei Live-Snapshots
    /// die Summe der bisher direkt darin gefundenen Dateien).
    var allocated = MappedBuffer<UInt64>()
    var logical = MappedBuffer<UInt64>()
    /// Eigene Dateianzahl (Dateien: 1, Ordner: 0 bzw. direkt gefundene Dateien).
    var ownFiles = MappedBuffer<UInt32>()
    var names = MappedBuffer<UInt8>()

    init() {}

    var count: Int { parent.count }

    mutating func reserve(_ n: Int, nameBytes: Int) {
        parent.reserve(n)
        nameOffset.reserve(n)
        nameLength.reserve(n)
        flags.reserve(n)
        allocated.reserve(n)
        logical.reserve(n)
        ownFiles.reserve(n)
        names.reserve(nameBytes)
    }

    @discardableResult
    mutating func append(
        parent p: Int32, name: UnsafeBufferPointer<UInt8>, flags f: NodeFlags,
        allocated a: UInt64, logical l: UInt64, ownFiles o: UInt32
    ) -> Int32 {
        let idx = Int32(parent.count)
        parent.append(p)
        nameOffset.append(UInt32(names.count))
        let len = min(name.count, Int(UInt16.max))
        nameLength.append(UInt16(len))
        names.append(contentsOf: UnsafeBufferPointer(rebasing: name[0 ..< len]))
        flags.append(f.rawValue)
        allocated.append(a)
        logical.append(l)
        ownFiles.append(o)
        return idx
    }

    @discardableResult
    mutating func append(
        parent p: Int32, name: [UInt8], flags f: NodeFlags,
        allocated a: UInt64, logical l: UInt64, ownFiles o: UInt32
    ) -> Int32 {
        name.withUnsafeBufferPointer {
            append(parent: p, name: $0, flags: f, allocated: a, logical: l, ownFiles: o)
        }
    }

    func copy() -> RawTree {
        var c = RawTree()
        c.parent = parent.copy()
        c.nameOffset = nameOffset.copy()
        c.nameLength = nameLength.copy()
        c.flags = flags.copy()
        c.allocated = allocated.copy()
        c.logical = logical.copy()
        c.ownFiles = ownFiles.copy()
        c.names = names.copy()
        return c
    }
}

/// Datei mit `nlink > 1`: Gerät, Inode, Knotenindex und echte Größe (auch
/// wenn der Knoten als Duplikat mit 0 Byte zählt). Der Baum behält diese
/// schlanke Tabelle, damit ein Teil-Rescan Hardlinks korrekt bereinigen kann.
struct HardlinkEntry: Sendable, Equatable {
    var dev: Int32
    var ino: UInt64
    var index: Int32
    var allocated: UInt64
    var logical: UInt64
}

/// Fehler beim Aufbau, z. B. Abbruch.
enum TreeBuildError: Error { case cancelled }

/// Baut aus einem Rohbaum den sortierten, kompakten `ScanTree`:
/// Größen nach oben propagieren, Kinder absteigend sortieren und in
/// Breitensuche-Reihenfolge zusammenhängend ablegen.
enum TreeBuilder {
    /// Rohbaum in Spaltenform (Live-Snapshots, Tests, `ScanTreeBuilder`).
    static func build(
        _ rawIn: consuming RawTree,
        rootPath: String,
        hardlinks: [HardlinkEntry] = [],
        isCancelled: () -> Bool = { false },
        indexMap: ((UnsafeBufferPointer<Int32>) -> Void)? = nil,
        partial: Bool = false
    ) throws -> ScanTree {
        var raw = rawIn
        let n = raw.count
        precondition(n > 0 && n < Int(Int32.max))
        var nodes = [Node](unsafeUninitializedCapacity: n) { buf, initialized in
            for i in 0 ..< n {
                buf.initializeElement(at: i, to: Node(
                    allocatedSize: raw.allocated[i], logicalSize: raw.logical[i], parent: raw.parent[i],
                    firstChild: 0, childCount: 0, nameOffset: raw.nameOffset[i], fileCount: raw.ownFiles[i],
                    nameLength: raw.nameLength[i], flags: NodeFlags(rawValue: raw.flags[i])))
            }
            initialized = n
        }
        raw.parent = MappedBuffer()
        raw.allocated = MappedBuffer()
        raw.logical = MappedBuffer()
        raw.ownFiles = MappedBuffer()
        let tree = try buildInPlace(nodes: &nodes, names: UnsafeBufferPointer(raw.names.buffer), rootPath: rootPath,
                                    hardlinks: hardlinks, isCancelled: isCancelled, indexMap: indexMap,
                                    partial: partial)
        withExtendedLifetime(raw) {}
        return tree
    }

    /// Aufbau ohne Abbruch-Callback (Vergleichsbäume, `ScanTreeBuilder`).
    /// `build` wirft nur `TreeBuildError.cancelled`, und das nur über
    /// `isCancelled`; ohne Callback kann der Aufbau also nicht fehlschlagen.
    static func buildUncancellable(
        _ raw: consuming RawTree,
        rootPath: String,
        indexMap: ((UnsafeBufferPointer<Int32>) -> Void)? = nil
    ) -> ScanTree {
        do {
            return try build(raw, rootPath: rootPath, indexMap: indexMap)
        } catch {
            preconditionFailure("TreeBuilder.build ohne Abbruch-Callback ist fehlgeschlagen: \(error)")
        }
    }

    /// Ordnet ein Knoten-Array an Ort und Stelle zum fertigen Baum.
    ///
    /// Eingabe: Knoten in beliebiger Reihenfolge mit Index 0 als Wurzel;
    /// `parent` ist ein Index in dasselbe Array, Größen und `fileCount` sind
    /// die eigenen Werte, `firstChild`/`childCount` werden ignoriert. Knoten
    /// mit dem Flag `.dead` müssen Blätter sein und fallen weg.
    ///
    /// Speicher neben Knoten-Array und Namen: 16 Byte pro Knoten in
    /// `MappedBuffer`s (Kinderlisten, Reihenfolge, Index-Abbildung). Die
    /// Knoten werden per Zyklen-Permutation an Ort und Stelle umsortiert,
    /// es entsteht kein zweites Knoten-Array (siehe dev/PERFORMANCE.md).
    static func buildInPlace(
        nodes: inout [Node],
        names nm: UnsafeBufferPointer<UInt8>,
        rootPath: String,
        hardlinks rawLinks: [HardlinkEntry] = [],
        isCancelled: () -> Bool = { false },
        indexMap: ((UnsafeBufferPointer<Int32>) -> Void)? = nil,
        partial: Bool = false
    ) throws -> ScanTree {
        let n = nodes.count
        precondition(n > 0 && n < Int(Int32.max))
        var live = 1
        // Ein Teilbaum (Live-Snapshot) ist nie vollständig, auch wenn noch
        // kein Ordner vorläufige Größen trägt.
        var complete = !partial
        var links = rawLinks
        try nodes.withUnsafeMutableBufferPointer { nb in
            // 1. Kinder je Elternknoten zählen (CSR-Darstellung).
            for i in 0 ..< n {
                nb[i].childCount = 0
                if nb[i].isDirectory, nb[i].fileCount != 0 || nb[i].logicalSize != 0 { complete = false }
            }
            for i in 1 ..< n where !nb[i].flags.contains(.dead) {
                nb[Int(nb[i].parent)].childCount += 1
                live += 1
            }
            let startBuf = MappedBuffer<Int32>(zeroedCount: n + 1)
            let start = startBuf.buffer
            for i in 0 ..< n { start[i + 1] = start[i] + nb[i].childCount }
            var childBuf = MappedBuffer<Int32>(zeroedCount: max(n - 1, 1))
            let childList = childBuf.buffer
            // `firstChild` dient vorübergehend als Schreibcursor.
            for i in 0 ..< n { nb[i].firstChild = start[i] }
            for i in 1 ..< n where !nb[i].flags.contains(.dead) {
                let p = Int(nb[i].parent)
                childList[Int(nb[p].firstChild)] = Int32(i)
                nb[p].firstChild += 1
            }
            if isCancelled() { throw TreeBuildError.cancelled }

            // 2. Breitensuche ab der Wurzel → topologische Reihenfolge.
            let orderBuf = MappedBuffer<Int32>(zeroedCount: n)
            let order = orderBuf.buffer
            order[0] = 0
            var filled = 1
            var k = 0
            while k < filled {
                let v = Int(order[k])
                for c in start[v] ..< start[v + 1] {
                    order[filled] = childList[Int(c)]
                    filled += 1
                }
                k += 1
                if k & 0xFFFF == 0, isCancelled() { throw TreeBuildError.cancelled }
            }
            precondition(filled == live, "Rohbaum ist nicht zusammenhängend")

            // 3. Größen und Dateianzahl von unten nach oben aufsummieren.
            for j in stride(from: live - 1, to: 0, by: -1) {
                let v = Int(order[j])
                let p = Int(nb[v].parent)
                nb[p].allocatedSize &+= nb[v].allocatedSize
                nb[p].logicalSize &+= nb[v].logicalSize
                nb[p].fileCount &+= nb[v].fileCount
            }
            if isCancelled() { throw TreeBuildError.cancelled }

            // 4. Kinder jedes Knotens sortieren: Größe absteigend, dann logische
            //    Größe absteigend, dann Name aufsteigend (eindeutig je Ordner).
            let base = UnsafeBufferPointer(nb)
            for v in 0 ..< n {
                let s = Int(start[v]), e = Int(start[v + 1])
                if e - s < 2 { continue }
                var segment = UnsafeMutableBufferPointer(rebasing: childList[s ..< e])
                segment.sort { a, b in Self.precedes(base[Int(a)], base[Int(b)], nm) }
                if v & 0xFFFF == 0, isCancelled() { throw TreeBuildError.cancelled }
            }

            // 5. Endgültige Anordnung: Breitensuche über die sortierten Kinder.
            //    `order` wird zur Abbildung neu → alt, `newIndex` zu alt → neu.
            //    Verworfene Knoten kommen ans Ende.
            let newIndexBuf = MappedBuffer<Int32>(zeroedCount: n)
            let newIndex = newIndexBuf.buffer
            order[0] = 0
            var next = 1
            for newIdx in 0 ..< live {
                let old = Int(order[newIdx])
                newIndex[old] = Int32(newIdx)
                for c in start[old] ..< start[old + 1] {
                    order[next] = childList[Int(c)]
                    next += 1
                }
            }
            for i in 1 ..< n where nb[i].flags.contains(.dead) {
                order[next] = Int32(i)
                newIndex[i] = Int32(next)
                next += 1
            }
            childBuf = MappedBuffer() // Kinderliste sofort freigeben
            if isCancelled() { throw TreeBuildError.cancelled }

            // 6. Zeiger auf die neuen Indizes umstellen (noch an den alten Plätzen).
            var firstChild: Int32 = 1
            for newIdx in 0 ..< live {
                let old = Int(order[newIdx])
                nb[old].firstChild = firstChild
                firstChild += nb[old].childCount
                nb[old].parent = newIdx == 0 ? -1 : newIndex[Int(nb[old].parent)]
            }
            for i in links.indices { links[i].index = newIndex[Int(links[i].index)] }
            // Abbildung Eingabe-Index → Baum-Index (verworfene: ≥ Knotenzahl).
            indexMap?(UnsafeBufferPointer(newIndex))

            // 7. Zyklen-Permutation an Ort und Stelle: neu[j] = alt[order[j]].
            //    Erledigte Plätze werden mit order[j] = j markiert.
            for s in 0 ..< n where order[s] != Int32(s) {
                let tmp = nb[s]
                var j = s
                while true {
                    let src = Int(order[j])
                    order[j] = Int32(j)
                    if src == s {
                        nb[j] = tmp
                        break
                    }
                    nb[j] = nb[src]
                    j = src
                }
            }
            withExtendedLifetime(startBuf) {}
            withExtendedLifetime(orderBuf) {}
            withExtendedLifetime(newIndexBuf) {}
        }
        if live < n { nodes.removeLast(n - live) }
        links.removeAll { $0.index >= Int32(live) }
        links.sort { $0.index < $1.index }

        // 8. Namen in Baum-Reihenfolge kopieren.
        var nameTotal = 0
        for i in 0 ..< live { nameTotal += Int(nodes[i].nameLength) }
        let names = nodes.withUnsafeMutableBufferPointer { nb in
            [UInt8](unsafeUninitializedCapacity: max(nameTotal, 1)) { buf, initialized in
                var pos = 0
                for i in 0 ..< live {
                    let off = Int(nb[i].nameOffset), len = Int(nb[i].nameLength)
                    if len > 0 {
                        UnsafeMutableRawPointer(buf.baseAddress! + pos)
                            .copyMemory(from: nm.baseAddress! + off, byteCount: len)
                    }
                    nb[i].nameOffset = UInt32(pos)
                    pos += len
                }
                initialized = pos
            }
        }
        return ScanTree(rootPath: rootPath, nodes: nodes, names: names, hardlinks: links, isComplete: complete)
    }

    /// Sortierregel für Geschwister: belegte Größe absteigend, dann logische
    /// Größe absteigend, dann Name aufsteigend (UTF-8-Bytes).
    @inline(__always)
    static func precedes(_ a: Node, _ b: Node, _ nm: UnsafeBufferPointer<UInt8>) -> Bool {
        if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
        if a.logicalSize != b.logicalSize { return a.logicalSize > b.logicalSize }
        return compareNames(nm, a.nameOffset, a.nameLength, b.nameOffset, b.nameLength) < 0
    }

    @inline(__always)
    static func compareNames(
        _ nm: UnsafeBufferPointer<UInt8>, _ oa: UInt32, _ la: UInt16, _ ob: UInt32, _ lb: UInt16
    ) -> Int32 {
        guard let base = nm.baseAddress else { return Int32(la) - Int32(lb) }
        let r = memcmp(base + Int(oa), base + Int(ob), Int(min(la, lb)))
        if r != 0 { return r }
        return Int32(la) - Int32(lb)
    }
}
