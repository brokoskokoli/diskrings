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

/// Fehler beim Aufbau, z. B. Abbruch.
enum TreeBuildError: Error { case cancelled }

/// Baut aus einem Rohbaum den sortierten, kompakten `ScanTree`:
/// Größen nach oben propagieren, Kinder absteigend sortieren und in
/// Breitensuche-Reihenfolge zusammenhängend ablegen.
///
/// Speicherbedarf neben Rohbaum und Ergebnis: 16 Byte pro Knoten, alles in
/// `MappedBuffer`s, die beim Verlassen sofort freigegeben werden.
enum TreeBuilder {
    static func build(
        _ rawIn: consuming RawTree,
        rootPath: String,
        isCancelled: () -> Bool = { false }
    ) throws -> ScanTree {
        var raw = rawIn
        let n = raw.count
        precondition(n > 0 && n < Int(Int32.max))
        let parent = raw.parent.buffer
        let alloc = raw.allocated.buffer
        let logi = raw.logical.buffer
        let files = raw.ownFiles.buffer
        let nameOff = raw.nameOffset.buffer
        let nameLen = raw.nameLength.buffer
        let flags = raw.flags.buffer
        let nm = UnsafeBufferPointer(raw.names.buffer)

        // 1. Kinder je Elternknoten zählen (CSR-Darstellung).
        let startBuf = MappedBuffer<Int32>(zeroedCount: n + 1)
        let start = startBuf.buffer
        for i in 1 ..< n { start[Int(parent[i]) + 1] += 1 }
        for i in 0 ..< n { start[i + 1] += start[i] }
        var childBuf = MappedBuffer<Int32>(zeroedCount: max(n - 1, 1))
        let childList = childBuf.buffer
        // `order` dient zuerst als Schreibcursor, dann als Breitensuche-Reihenfolge.
        let orderBuf = MappedBuffer<Int32>(zeroedCount: n)
        let order = orderBuf.buffer
        for i in 0 ..< n { order[i] = start[i] }
        for i in 1 ..< n {
            let p = Int(parent[i])
            childList[Int(order[p])] = Int32(i)
            order[p] += 1
        }
        if isCancelled() { throw TreeBuildError.cancelled }

        // 2. Breitensuche ab der Wurzel → topologische Reihenfolge.
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
        precondition(filled == n, "Rohbaum ist nicht zusammenhängend")

        // 3. Größen und Dateianzahl von unten nach oben aufsummieren.
        for j in stride(from: n - 1, to: 0, by: -1) {
            let v = Int(order[j])
            let p = Int(parent[v])
            alloc[p] &+= alloc[v]
            logi[p] &+= logi[v]
            files[p] &+= files[v]
        }
        if isCancelled() { throw TreeBuildError.cancelled }

        // 4. Kinder jedes Knotens sortieren: Größe absteigend, dann logische
        //    Größe absteigend, dann Name aufsteigend (eindeutig je Ordner).
        for v in 0 ..< n {
            let s = Int(start[v]), e = Int(start[v + 1])
            if e - s < 2 { continue }
            var segment = UnsafeMutableBufferPointer(rebasing: childList[s ..< e])
            segment.sort { a, b in
                let ia = Int(a), ib = Int(b)
                if alloc[ia] != alloc[ib] { return alloc[ia] > alloc[ib] }
                if logi[ia] != logi[ib] { return logi[ia] > logi[ib] }
                return compareNames(nm, nameOff[ia], nameLen[ia], nameOff[ib], nameLen[ib]) < 0
            }
            if v & 0xFFFF == 0, isCancelled() { throw TreeBuildError.cancelled }
        }

        // 5. Endgültige Anordnung: Breitensuche über die sortierten Kinder.
        //    `order` wird zur Abbildung neu → alt, `newIndex` zu alt → neu.
        let newIndexBuf = MappedBuffer<Int32>(zeroedCount: n)
        let newIndex = newIndexBuf.buffer
        order[0] = 0
        var next = 1
        for newIdx in 0 ..< n {
            let old = Int(order[newIdx])
            newIndex[old] = Int32(newIdx)
            for c in start[old] ..< start[old + 1] {
                order[next] = childList[Int(c)]
                next += 1
            }
        }
        if isCancelled() { throw TreeBuildError.cancelled }
        // Die Kinderliste wird nicht mehr gebraucht: sofort freigeben, damit
        // die Speicherspitze beim Anlegen des Ergebnisses kleiner bleibt.
        childBuf = MappedBuffer()

        let names = [UInt8](unsafeUninitializedCapacity: max(nm.count, 1)) { buf, initialized in
            var pos = 0
            for newIdx in 0 ..< n {
                let old = Int(order[newIdx])
                let off = Int(nameOff[old]), len = Int(nameLen[old])
                if len > 0 {
                    UnsafeMutableRawPointer(buf.baseAddress! + pos)
                        .copyMemory(from: nm.baseAddress! + off, byteCount: len)
                }
                pos += len
            }
            initialized = pos
        }
        raw.names = MappedBuffer() // Rohnamen freigeben
        let nodes = [Node](unsafeUninitializedCapacity: n) { buf, initialized in
            var namePos: UInt32 = 0
            var firstChild = 1
            for newIdx in 0 ..< n {
                let old = Int(order[newIdx])
                let childCount = Int(start[old + 1] - start[old])
                let len = nameLen[old]
                buf.initializeElement(at: newIdx, to: Node(
                    allocatedSize: alloc[old],
                    logicalSize: logi[old],
                    parent: newIdx == 0 ? -1 : newIndex[Int(parent[old])],
                    firstChild: Int32(firstChild),
                    childCount: Int32(childCount),
                    nameOffset: namePos,
                    fileCount: files[old],
                    nameLength: len,
                    flags: NodeFlags(rawValue: flags[old])
                ))
                namePos += UInt32(len)
                firstChild += childCount
            }
            initialized = n
        }
        withExtendedLifetime(startBuf) {}
        withExtendedLifetime(orderBuf) {}
        withExtendedLifetime(newIndexBuf) {}
        withExtendedLifetime(raw) {}
        return ScanTree(rootPath: rootPath, nodes: nodes, names: names)
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
