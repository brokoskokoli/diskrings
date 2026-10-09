import Darwin

/// Unsortierter Rohbaum in Spaltenform (structure of arrays), wie ihn der
/// Scanner bzw. die Live-Snapshots liefern. Knoten 0 ist die Wurzel; die
/// Eltern dürfen in beliebiger Reihenfolge stehen.
struct RawTree {
    var parent: [Int32] = []
    var nameOffset: [UInt32] = []
    var nameLength: [UInt16] = []
    var flags: [UInt16] = []
    /// Eigene Größe des Knotens (bei Ordnern in der Regel 0, bei Live-Snapshots
    /// die Summe der bisher direkt darin gefundenen Dateien).
    var allocated: [UInt64] = []
    var logical: [UInt64] = []
    /// Eigene Dateianzahl (Dateien: 1, Ordner: 0 bzw. direkt gefundene Dateien).
    var ownFiles: [UInt32] = []
    var names: [UInt8] = []

    var count: Int { parent.count }

    mutating func reserve(_ n: Int) {
        parent.reserveCapacity(n)
        nameOffset.reserveCapacity(n)
        nameLength.reserveCapacity(n)
        flags.reserveCapacity(n)
        allocated.reserveCapacity(n)
        logical.reserveCapacity(n)
        ownFiles.reserveCapacity(n)
    }

    @discardableResult
    mutating func append<C: Collection>(
        parent p: Int32, name: C, flags f: NodeFlags,
        allocated a: UInt64, logical l: UInt64, ownFiles o: UInt32
    ) -> Int32 where C.Element == UInt8 {
        let idx = Int32(parent.count)
        parent.append(p)
        nameOffset.append(UInt32(names.count))
        let len = min(name.count, Int(UInt16.max))
        nameLength.append(UInt16(len))
        names.append(contentsOf: name.prefix(len))
        flags.append(f.rawValue)
        allocated.append(a)
        logical.append(l)
        ownFiles.append(o)
        return idx
    }
}

/// Fehler beim Aufbau, z. B. Abbruch.
enum TreeBuildError: Error { case cancelled }

/// Baut aus einem Rohbaum den sortierten, kompakten `ScanTree`:
/// Größen nach oben propagieren, Kinder absteigend sortieren und in
/// Breitensuche-Reihenfolge zusammenhängend ablegen.
enum TreeBuilder {
    static func build(
        _ rawIn: consuming RawTree,
        rootPath: String,
        isCancelled: () -> Bool = { false }
    ) throws -> ScanTree {
        var raw = rawIn
        let n = raw.count
        precondition(n > 0 && n < Int(Int32.max))

        // 1. Kinder je Elternknoten zählen (CSR-Darstellung).
        var start = [Int32](repeating: 0, count: n + 1)
        for i in 1 ..< n { start[Int(raw.parent[i]) + 1] += 1 }
        for i in 0 ..< n { start[i + 1] += start[i] }
        var childList = [Int32](repeating: 0, count: max(n - 1, 0))
        do {
            var cursor = start
            for i in 1 ..< n {
                let p = Int(raw.parent[i])
                childList[Int(cursor[p])] = Int32(i)
                cursor[p] += 1
            }
        }
        if isCancelled() { throw TreeBuildError.cancelled }

        // 2. Breitensuche ab der Wurzel → topologische Reihenfolge.
        var order = [Int32](repeating: 0, count: n)
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
        precondition(filled == n, "Rohbaum ist nicht zusammenhängend")

        // 3. Größen und Dateianzahl von unten nach oben aufsummieren.
        raw.allocated.withUnsafeMutableBufferPointer { alloc in
            raw.logical.withUnsafeMutableBufferPointer { logi in
                raw.ownFiles.withUnsafeMutableBufferPointer { files in
                    raw.parent.withUnsafeBufferPointer { par in
                        for j in stride(from: n - 1, to: 0, by: -1) {
                            let v = Int(order[j])
                            let p = Int(par[v])
                            alloc[p] &+= alloc[v]
                            logi[p] &+= logi[v]
                            files[p] &+= files[v]
                        }
                    }
                }
            }
        }
        if isCancelled() { throw TreeBuildError.cancelled }

        // 4. Kinder jedes Knotens sortieren.
        raw.names.withUnsafeBufferPointer { nm in
            raw.allocated.withUnsafeBufferPointer { alloc in
                raw.logical.withUnsafeBufferPointer { logi in
                    raw.nameOffset.withUnsafeBufferPointer { off in
                        raw.nameLength.withUnsafeBufferPointer { len in
                            childList.withUnsafeMutableBufferPointer { list in
                                for v in 0 ..< n {
                                    let s = Int(start[v]), e = Int(start[v + 1])
                                    if e - s < 2 { continue }
                                    list[s ..< e].sort { a, b in
                                        let ia = Int(a), ib = Int(b)
                                        if alloc[ia] != alloc[ib] { return alloc[ia] > alloc[ib] }
                                        if logi[ia] != logi[ib] { return logi[ia] > logi[ib] }
                                        return compareNames(nm, off[ia], len[ia], off[ib], len[ib]) < 0
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if isCancelled() { throw TreeBuildError.cancelled }

        // 5. Endgültige Anordnung: Breitensuche über die sortierten Kinder.
        //    `order` wird als Abbildung neu → alt wiederverwendet.
        var nodes = [Node]()
        nodes.reserveCapacity(n)
        var names = [UInt8]()
        names.reserveCapacity(raw.names.count)
        order[0] = 0
        var next = 1
        for newIdx in 0 ..< n {
            let old = Int(order[newIdx])
            let s = Int(start[old]), e = Int(start[old + 1])
            let off = Int(raw.nameOffset[old]), len = Int(raw.nameLength[old])
            let nameOff = UInt32(names.count)
            names.append(contentsOf: raw.names[off ..< off + len])
            nodes.append(Node(
                allocatedSize: raw.allocated[old],
                logicalSize: raw.logical[old],
                parent: newIdx == 0 ? -1 : raw.parent[old], // vorläufig alter Index, unten korrigiert
                firstChild: Int32(next),
                childCount: Int32(e - s),
                nameOffset: nameOff,
                fileCount: raw.ownFiles[old],
                nameLength: UInt16(len),
                flags: NodeFlags(rawValue: raw.flags[old])
            ))
            for c in s ..< e {
                order[next] = childList[c]
                next += 1
            }
            if newIdx & 0xFFFF == 0xFFFF, isCancelled() { throw TreeBuildError.cancelled }
        }
        // Elternindizes auf die neue Anordnung umstellen.
        for newIdx in 0 ..< n {
            let r = nodes[newIdx].childIndexRange
            for c in r { nodes[c].parent = Int32(newIdx) }
        }
        return ScanTree(rootPath: rootPath, nodes: nodes, names: names)
    }

    @inline(__always)
    static func compareNames(
        _ nm: UnsafeBufferPointer<UInt8>, _ oa: UInt32, _ la: UInt16, _ ob: UInt32, _ lb: UInt16
    ) -> Int32 {
        let m = Int(min(la, lb))
        guard let base = nm.baseAddress else { return Int32(la) - Int32(lb) }
        let r = memcmp(base + Int(oa), base + Int(ob), m)
        if r != 0 { return r }
        return Int32(la) - Int32(lb)
    }
}

extension Node {
    var childIndexRange: Range<Int> { Int(firstChild) ..< Int(firstChild) + Int(childCount) }
}
