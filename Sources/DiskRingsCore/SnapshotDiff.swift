import Foundation

/// Status eines Knotens im Vergleich (SPEC 3.9).
public enum DiffStatus: UInt8, Sendable, CaseIterable {
    /// Nur im neuen Baum.
    case added
    /// Nur im alten Baum.
    case removed
    case grown
    case shrunk
    case unchanged
}

/// Ein Knoten des Vergleichsbaums: Vereinigung beider Bäume, über den Pfad
/// zugeordnet. Größen kommen aus den Bäumen (`SnapshotDiff.old/new`).
public struct DiffEntry: Sendable, Equatable {
    /// Index im alten Baum, -1 = nicht vorhanden.
    public let oldIndex: Int32
    /// Index im neuen Baum, -1 = nicht vorhanden.
    public let newIndex: Int32
    /// Index des Eltern-Eintrags, -1 bei der Wurzel.
    public let parent: Int32
    /// Kinder liegen zusammenhängend ab `firstChild` (nach Name sortiert).
    public internal(set) var firstChild: Int32
    public internal(set) var childCount: Int32
}

/// Eine Zeile der Liste „Größte Veränderungen“.
public struct DiffChange: Sendable, Equatable {
    public let entry: Int32
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let oldSize: UInt64
    public let newSize: UInt64
    /// Netto-Änderung des Knotens (`neu − alt`).
    public let delta: Int64
    /// Brutto-Zuwachs (bzw. -Rückgang) im Teilbaum, nach dem sortiert wird:
    /// Summe der positiven (bzw. negativen) Änderungen darin. Bei Dateien und
    /// Teilbäumen, die nur wachsen, gleich `|delta|`.
    public let amount: UInt64
    public let status: DiffStatus
}

/// Kopfzeilen-Kennzahlen (SPEC 3.9: „Seit 02.10., 09:14: belegt +38,2 GB ·
/// frei −38,2 GB · davon nicht zugeordnet +4,1 GB“).
public struct DiffSummary: Sendable, Equatable {
    public let oldDate: Date
    public let newDate: Date
    /// Änderung der Scan-Summe (belegt).
    public let scanDelta: Int64
    /// Änderung von „belegt“ laut Volume (nur mit Volume-Kennzahlen).
    public let usedDelta: Int64?
    /// Änderung von „frei“ laut Volume.
    public let freeDelta: Int64?
    /// Änderung von „nicht zugeordnet“ (nur, wenn beide Seiten die
    /// Volume-Wurzel gescannt haben).
    public let unassignedDelta: Int64?

    /// Kurze Kopfzeile (CLI), z. B. „Since 10/02, 9:14 AM: used +38.2 GB · free −38.2 GB · of which unassigned +4.1 GB“.
    public var headline: String {
        var parts: [String] = []
        if let u = usedDelta { parts.append(L("compare.part.used", ByteFormat.signed(u))) } else {
            parts.append(L("compare.part.scan", ByteFormat.signed(scanDelta)))
        }
        if let fr = freeDelta { parts.append(L("compare.part.free", ByteFormat.signed(fr))) }
        if let n = unassignedDelta { parts.append(L("compare.part.unassigned", ByteFormat.signed(n))) }
        return TextFormat.labeled(L("compare.since", CompareHeadline.shortDate(oldDate)), TextFormat.inline(parts))
    }
}

/// Hinweise, wenn die beiden Seiten nicht direkt vergleichbar sind.
public enum DiffWarning: Sendable, Equatable, CustomStringConvertible {
    /// Andere Scan-Einstellungen (z. B. ohne versteckte Dateien).
    case differentOptions(old: SnapshotScanOptions, new: SnapshotScanOptions)
    case differentRoot(old: String, new: String)
    case differentVolume(old: String?, new: String?)
    /// Unterschiedliche Mindestgröße: Dateien darunter werden auf beiden
    /// Seiten nur über die Ordnersumme verglichen.
    case differentMinimumFileSize(old: UInt64, new: UInt64)

    public var description: String {
        switch self {
        case .differentOptions(let o, let n):
            var why: [String] = []
            if o.includeHidden != n.includeHidden {
                why.append(n.includeHidden ? L("compare.warning.hiddenBefore") : L("compare.warning.hiddenNow"))
            }
            if o.excludedPaths != n.excludedPaths { why.append(L("compare.warning.exclusions")) }
            if o.crossMountPoints != n.crossMountPoints { why.append(L("compare.warning.volumes")) }
            return L("compare.warning.options", why.joined(separator: L("list.separator")))
        case .differentRoot(let o, let n): return L("compare.warning.root", o, n)
        case .differentVolume: return L("compare.warning.volume")
        case .differentMinimumFileSize(let o, let n):
            return L("compare.warning.minimumSize", ByteFormat.string(max(o, n)))
        }
    }
}

/// Vergleich zweier Bäume über den Pfad (SPEC 3.9): Snapshot gegen Snapshot
/// oder Snapshot gegen frischen Scan (`Snapshot(metadata: .current(for:), tree:)`).
///
/// Beide Bäume werden ab der Wurzel parallel durchlaufen; die Kinder jedes
/// Paars werden nach Name sortiert und gemischt (O(n log k) bei k Kindern
/// pro Ordner, praktisch linear). Dateien unter der größeren der beiden
/// Mindestgrößen werden auf beiden Seiten nicht einzeln verglichen, sondern
/// nur über die Ordnersumme (sonst erschienen alle kleinen Dateien eines
/// frischen Scans als „neu“).
public final class SnapshotDiff: Sendable {
    public let old: Snapshot
    public let new: Snapshot
    /// Vereinigungsbaum in Breitensuche-Reihenfolge, Eintrag 0 = Wurzel.
    public let entries: [DiffEntry]
    /// Index im alten bzw. neuen Baum → Eintrag (-1 = kein Eintrag, z. B.
    /// kleine Datei oder toter Knoten).
    public let entryForOld: [Int32]
    public let entryForNew: [Int32]
    /// Dateien darunter werden nur über die Ordnersumme verglichen.
    public let minimumFileSize: UInt64
    public let summary: DiffSummary
    public let warnings: [DiffWarning]

    public convenience init(old: Snapshot, new: Snapshot) {
        self.init(old: old, new: new, minimumFileSize: nil)
    }

    /// - Parameter minimumFileSize: Standard ist die größere Mindestgröße
    ///   der beiden Snapshots.
    public init(old: Snapshot, new: Snapshot, minimumFileSize: UInt64?) {
        self.old = old
        self.new = new
        let minSize = minimumFileSize ?? max(old.metadata.minimumFileSize, new.metadata.minimumFileSize)
        self.minimumFileSize = minSize
        let built = Self.merge(old.tree, new.tree, minSize: minSize)
        entries = built.entries
        entryForOld = built.oldMap
        entryForNew = built.newMap

        let om = old.metadata, nm = new.metadata
        func d(_ a: UInt64?, _ b: UInt64?) -> Int64? {
            guard let a, let b else { return nil }
            return Int64(bitPattern: b &- a)
        }
        summary = DiffSummary(
            oldDate: om.date, newDate: nm.date,
            scanDelta: Int64(bitPattern: new.tree.root.allocatedSize &- old.tree.root.allocatedSize),
            usedDelta: d(om.volume?.used, nm.volume?.used),
            freeDelta: d(om.volume?.available, nm.volume?.available),
            unassignedDelta: d(om.volume?.unassigned, nm.volume?.unassigned))

        var w: [DiffWarning] = []
        if om.options != nm.options { w.append(.differentOptions(old: om.options, new: nm.options)) }
        if om.rootPath != nm.rootPath { w.append(.differentRoot(old: om.rootPath, new: nm.rootPath)) }
        if om.volumeUUID != nm.volumeUUID { w.append(.differentVolume(old: om.volumeUUID, new: nm.volumeUUID)) }
        // Ein frischer Scan hat keine Mindestgröße; das ist der Normalfall
        // und kein Grund für eine Warnung.
        if om.minimumFileSize != nm.minimumFileSize, om.minimumFileSize > 0, nm.minimumFileSize > 0 {
            w.append(.differentMinimumFileSize(old: om.minimumFileSize, new: nm.minimumFileSize))
        }
        warnings = w
    }

    // MARK: Zugriff pro Eintrag

    public var count: Int { entries.count }

    public func oldSize(_ e: Int32, _ mode: SizeMode = .allocated) -> UInt64 {
        let i = entries[Int(e)].oldIndex
        return i < 0 ? 0 : old.tree.nodes[Int(i)].size(mode)
    }

    public func newSize(_ e: Int32, _ mode: SizeMode = .allocated) -> UInt64 {
        let i = entries[Int(e)].newIndex
        return i < 0 ? 0 : new.tree.nodes[Int(i)].size(mode)
    }

    /// `neu − alt`.
    public func delta(_ e: Int32, _ mode: SizeMode = .allocated) -> Int64 {
        Int64(bitPattern: newSize(e, mode) &- oldSize(e, mode))
    }

    public func status(_ e: Int32, _ mode: SizeMode = .allocated) -> DiffStatus {
        let entry = entries[Int(e)]
        if entry.oldIndex < 0 { return .added }
        if entry.newIndex < 0 { return .removed }
        let d = delta(e, mode)
        return d > 0 ? .grown : d < 0 ? .shrunk : .unchanged
    }

    /// Knoten des neuen bzw. (bei entfernten) des alten Baums.
    func node(_ e: Int32) -> Node {
        let entry = entries[Int(e)]
        return entry.newIndex >= 0 ? new.tree.nodes[Int(entry.newIndex)] : old.tree.nodes[Int(entry.oldIndex)]
    }

    public func isDirectory(_ e: Int32) -> Bool { node(e).isDirectory }

    public func name(of e: Int32) -> String {
        let entry = entries[Int(e)]
        return entry.newIndex >= 0 ? new.tree.name(of: entry.newIndex) : old.tree.name(of: entry.oldIndex)
    }

    public func path(of e: Int32) -> String {
        let entry = entries[Int(e)]
        return entry.newIndex >= 0 ? new.tree.path(of: entry.newIndex) : old.tree.path(of: entry.oldIndex)
    }

    public func childEntries(of e: Int32) -> Range<Int32> {
        let entry = entries[Int(e)]
        return entry.firstChild ..< entry.firstChild + entry.childCount
    }

    /// Kinder nach Δ sortiert (absteigend; für die Detailliste, SPEC 3.9).
    public func childEntriesSortedByDelta(of e: Int32, _ mode: SizeMode = .allocated) -> [Int32] {
        childEntries(of: e).sorted { a, b in
            let da = delta(a, mode), db = delta(b, mode)
            return da != db ? da > db : name(of: a) < name(of: b)
        }
    }

    /// Eintrag für einen Pfad (über den neuen, sonst den alten Baum).
    public func entry(forPath path: String) -> Int32? {
        if let i = new.tree.index(ofPath: path), entryForNew[Int(i)] >= 0 { return entryForNew[Int(i)] }
        if let i = old.tree.index(ofPath: path), entryForOld[Int(i)] >= 0 { return entryForOld[Int(i)] }
        return nil
    }

    // MARK: Größte Veränderungen

    /// Anteil, ab dem ein Kind die Änderung seines Ordners „erklärt“.
    public static let dominanceShare = 0.5

    /// Flache Liste der größten Veränderungen (SPEC 3.9, Tab „Größte
    /// Veränderungen“), nur der **tiefste aussagekräftige** Knoten:
    ///
    /// Von der Wurzel abwärts: Erklärt ein einzelnes Kind mehr als die
    /// Hälfte der Änderung eines Ordners, steigt die Suche in alle Kinder mit
    /// einer Änderung ≥ `minimumDelta` ab (der Ordner selbst erscheint nicht).
    /// Sonst ist die Änderung über viele Kinder verteilt, und der Ordner
    /// erscheint selbst. Wächst `~/Library/Caches/foo` um 20 GB, steht dort
    /// also `foo` und nicht zusätzlich `Library` und `Caches`. Die Einträge
    /// sind nie Vorfahren voneinander.
    ///
    /// - Parameter growth: `true` = Zuwachs, `false` = Rückgang.
    public func largestChanges(limit: Int = 50, minimumDelta: UInt64 = 1_000_000, growth: Bool = true,
                               mode: SizeMode = .allocated) -> [DiffChange] {
        // Brutto-Werte: Wachstum und Rückgang in verschiedenen Zweigen sollen
        // sich weiter oben nicht gegenseitig aufheben (z. B. umbenannte Ordner).
        let (gross, _) = grossChanges(growth: growth, mode: mode)
        let minD = max(minimumDelta, 1)
        var found: [Int32] = []
        var stack: [Int32] = [0]
        while let e = stack.popLast() {
            let a = gross[Int(e)]
            guard a >= minD else { continue }
            var significant: [Int32] = []
            var dominated = false
            for c in childEntries(of: e) {
                let ac = gross[Int(c)]
                if ac >= minD { significant.append(c) }
                if Double(ac) > Self.dominanceShare * Double(a) { dominated = true }
            }
            if dominated {
                stack.append(contentsOf: significant)
            } else {
                found.append(e)
            }
        }
        found.sort { gross[Int($0)] != gross[Int($1)] ? gross[Int($0)] > gross[Int($1)] : path(of: $0) < path(of: $1) }
        return found.prefix(max(limit, 0)).map { e in
            DiffChange(entry: e, path: path(of: e), name: name(of: e), isDirectory: isDirectory(e),
                       oldSize: oldSize(e, mode), newSize: newSize(e, mode), delta: delta(e, mode),
                       amount: gross[Int(e)], status: status(e, mode))
        }
    }

    /// Brutto-Zuwachs (`growth`) bzw. -Rückgang pro Eintrag und der davon
    /// nicht auf Kinder verteilte Rest (z. B. kleine Dateien unter der
    /// Mindestgröße oder die Eigengröße eines Ordners), von unten nach oben.
    func grossChanges(growth: Bool, mode: SizeMode) -> (total: [UInt64], own: [UInt64]) {
        let n = entries.count
        var total = [UInt64](repeating: 0, count: n)
        var own = [UInt64](repeating: 0, count: n)
        for e in stride(from: n - 1, through: 0, by: -1) {
            let ei = Int32(e)
            var d = delta(ei, mode)
            var childSum: Int64 = 0
            var g: UInt64 = 0
            for c in childEntries(of: ei) {
                childSum &+= delta(c, mode)
                g &+= total[Int(c)]
            }
            d &-= childSum
            let rest = growth ? max(d, 0) : max(-d, 0)
            own[e] = UInt64(rest)
            total[e] = g &+ own[e]
        }
        return (total, own)
    }

    // MARK: Wachstums-Baum

    /// Baum „nur Wachstum“ für den Sunburst (SPEC 3.9): ein normaler
    /// `ScanTree` mit dem Pfad und den Namen des neuen Baums, dessen Größen
    /// den positiven Deltas entsprechen. Ein Ordner ist so groß wie das
    /// Wachstum seiner Kinder plus ein nicht aufgeschlüsselter positiver Rest
    /// (z. B. kleine Dateien unter der Mindestgröße). Knoten ohne Wachstum
    /// fehlen. `entryForGrowth` bildet Baum-Index → Vergleichseintrag ab.
    public func growthTree(mode: SizeMode = .allocated) -> (tree: ScanTree, entryForGrowth: [Int32]) {
        let n = entries.count
        let (growA, ownA) = grossChanges(growth: true, mode: .allocated)
        let (growL, ownL) = grossChanges(growth: true, mode: .logical)
        let primary = mode == .allocated ? growA : growL

        var raw = RawTree()
        var rawEntry: [Int32] = []
        var rawOf = [Int32](repeating: -1, count: n)
        let root = new.tree.nodes[0]
        raw.append(parent: -1, name: Array(new.tree.nameBytes(of: 0)), flags: root.flags.subtracting(.dead),
                   allocated: ownA[0], logical: ownL[0], ownFiles: 0)
        rawEntry.append(0)
        rawOf[0] = 0
        for e in 1 ..< n where primary[e] > 0 {
            let entry = entries[e]
            let p = rawOf[Int(entry.parent)]
            guard p >= 0, entry.newIndex >= 0 else { continue }
            let node = new.tree.nodes[Int(entry.newIndex)]
            let idx: Int32
            if node.isDirectory {
                idx = raw.append(parent: p, name: Array(new.tree.nameBytes(of: entry.newIndex)), flags: node.flags,
                                 allocated: ownA[e], logical: ownL[e], ownFiles: 0)
            } else {
                idx = raw.append(parent: p, name: Array(new.tree.nameBytes(of: entry.newIndex)), flags: node.flags,
                                 allocated: growA[e], logical: growL[e], ownFiles: 1)
            }
            rawOf[e] = idx
            rawEntry.append(Int32(e))
        }
        var map = [Int32](repeating: -1, count: rawEntry.count)
        // Ohne Abbruch-Callback kann der Aufbau nicht fehlschlagen.
        // swiftlint:disable:next force_try
        let tree = try! TreeBuilder.build(raw, rootPath: new.tree.rootPath, indexMap: { newIndex in
            for (r, e) in rawEntry.enumerated() { map[Int(newIndex[r])] = e }
        })
        return (tree, map)
    }

    // MARK: Abgleich

    struct Built {
        var entries: [DiffEntry]
        var oldMap: [Int32]
        var newMap: [Int32]
    }

    static func merge(_ a: ScanTree, _ b: ScanTree, minSize: UInt64) -> Built {
        var entries: [DiffEntry] = []
        entries.reserveCapacity(max(a.liveCount, b.liveCount) + max(a.liveCount, b.liveCount) / 8)
        var oldMap = [Int32](repeating: -1, count: a.count)
        var newMap = [Int32](repeating: -1, count: b.count)
        entries.append(DiffEntry(oldIndex: 0, newIndex: 0, parent: -1, firstChild: 1, childCount: 0))
        oldMap[0] = 0
        newMap[0] = 0
        var ka: [Int32] = [], kb: [Int32] = []
        a.names.withUnsafeBufferPointer { na in
            b.names.withUnsafeBufferPointer { nb in
                a.nodes.withUnsafeBufferPointer { an in
                    b.nodes.withUnsafeBufferPointer { bn in
                        func collect(_ nodes: UnsafeBufferPointer<Node>, _ names: UnsafeBufferPointer<UInt8>,
                                     _ i: Int32, into out: inout [Int32]) {
                            out.removeAll(keepingCapacity: true)
                            guard i >= 0 else { return }
                            let n = nodes[Int(i)]
                            for c in n.firstChild ..< n.firstChild + n.childCount {
                                let child = nodes[Int(c)]
                                if !child.isDirectory, child.allocatedSize < minSize { continue }
                                out.append(c)
                            }
                            if out.count > 1 {
                                out.withUnsafeMutableBufferPointer { buf in
                                    buf.sort { x, y in
                                        let p = nodes[Int(x)], q = nodes[Int(y)]
                                        return TreeBuilder.compareNames(names, p.nameOffset, p.nameLength,
                                                                        q.nameOffset, q.nameLength) < 0
                                    }
                                }
                            }
                        }
                        func cmp(_ x: Int32, _ y: Int32) -> Int32 {
                            let p = an[Int(x)], q = bn[Int(y)]
                            let l = Int(min(p.nameLength, q.nameLength))
                            let r = l == 0 ? 0 : memcmp(na.baseAddress! + Int(p.nameOffset), nb.baseAddress! + Int(q.nameOffset), l)
                            return r != 0 ? r : Int32(p.nameLength) - Int32(q.nameLength)
                        }
                        var k = 0
                        while k < entries.count {
                            let e = entries[k]
                            collect(an, na, e.oldIndex, into: &ka)
                            collect(bn, nb, e.newIndex, into: &kb)
                            let first = Int32(entries.count)
                            var i = 0, j = 0
                            while i < ka.count || j < kb.count {
                                let c: Int32 = i == ka.count ? 1 : j == kb.count ? -1 : cmp(ka[i], kb[j])
                                let o: Int32 = c <= 0 ? ka[i] : -1
                                let nw: Int32 = c >= 0 ? kb[j] : -1
                                if c <= 0 { i += 1 }
                                if c >= 0 { j += 1 }
                                let idx = Int32(entries.count)
                                if o >= 0 { oldMap[Int(o)] = idx }
                                if nw >= 0 { newMap[Int(nw)] = idx }
                                entries.append(DiffEntry(oldIndex: o, newIndex: nw, parent: Int32(k),
                                                         firstChild: 0, childCount: 0))
                            }
                            entries[k].firstChild = first
                            entries[k].childCount = Int32(entries.count) - first
                            k += 1
                        }
                    }
                }
            }
        }
        return Built(entries: entries, oldMap: oldMap, newMap: newMap)
    }
}
