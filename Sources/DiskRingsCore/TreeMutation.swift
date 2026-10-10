/// Ergebnis einer Änderung am Baum (Teil-Rescan, Entfernen, Kompaktierung).
///
/// Änderungen erzeugen eine **neue, unveränderliche** `ScanTree`-Version
/// (copy-on-write); der alte Baum bleibt gültig und unverändert. Siehe
/// docs/DECISIONS.md („Veränderbarer Baum“).
public struct TreeEdit: Sendable {
    /// Die neue Baum-Version.
    public let tree: ScanTree
    /// Index des bearbeiteten Knotens im neuen Baum. Beim Teil-Rescan ist das
    /// der neu eingelesene Knoten, beim Entfernen sein Elternknoten. Der Index
    /// kann sich gegenüber vorher ändern, weil Geschwister nach der neuen
    /// Größe umsortiert werden.
    public let index: Int32
    /// Belegte bzw. logische Größe des bearbeiteten Knotens vorher und nachher
    /// (beim Entfernen: des entfernten Knotens vorher, nachher 0).
    public let allocatedBefore: UInt64
    public let allocatedAfter: UInt64
    public let logicalBefore: UInt64
    public let logicalAfter: UInt64
    /// `true`, wenn der Baum dabei kompaktiert wurde (alle Indizes neu).
    public let compacted: Bool

    /// Knoten, die beim Umsortieren ihren Platz gewechselt haben (alt → neu).
    let relocations: [Int32: Int32]
    /// Nach einer Kompaktierung: alter Index → neuer Index (-1 = entfernt).
    let compactionMap: [Int32]?

    /// Änderung der belegten Größe (neu − alt).
    public var allocatedDelta: Int64 { Int64(bitPattern: allocatedAfter &- allocatedBefore) }
    public var logicalDelta: Int64 { Int64(bitPattern: logicalAfter &- logicalBefore) }

    /// Übersetzt einen Index des alten Baums in den neuen (z. B. für Fokus
    /// und Auswahl der Oberfläche). `nil`, wenn der Knoten nicht mehr lebt.
    public func translate(_ oldIndex: Int32) -> Int32? {
        var i = relocations[oldIndex] ?? oldIndex
        if let map = compactionMap {
            guard Int(i) < map.count else { return nil }
            i = map[Int(i)]
            if i < 0 { return nil }
        }
        guard Int(i) < tree.count, !tree.nodes[Int(i)].flags.contains(.dead) else { return nil }
        return i
    }
}

extension ScanTree {
    /// Anteil toter Knoten, ab dem kompaktiert wird (SPEC 3.8: 25 %).
    public static let compactionThreshold = 0.25

    /// Mehr als 25 % der Knoten sind tot.
    public var needsCompaction: Bool {
        Double(deadCount) > Double(count) * Self.compactionThreshold
    }

    /// Ersetzt den Teilbaum unter `index` durch `subtree` (Ergebnis eines
    /// Scans genau dieses Pfads) und gibt die neue Baum-Version zurück.
    ///
    /// - Der Knoten behält Namen und Elternknoten; Größen, Flags und Kinder
    ///   kommen aus `subtree`. Seine bisherigen Nachfahren werden als tot
    ///   markiert, die neuen hinten angehängt.
    /// - Die Größendifferenz wird bis zur Wurzel propagiert, und in jeder Ebene
    ///   werden die Geschwister neu sortiert (Kinder bleiben zusammenhängend
    ///   und absteigend sortiert).
    /// - Hardlinks werden über den ganzen Baum neu bereinigt: Pro (Gerät,
    ///   Inode) zählt weiterhin das Vorkommen mit dem kleinsten Pfad.
    /// - Mit `compactIfNeeded` wird kompaktiert, sobald mehr als 25 % der
    ///   Knoten tot sind (dann ändern sich alle Indizes, siehe `TreeEdit`).
    public func replacingSubtree(at index: Int32, with subtree: ScanTree, compactIfNeeded: Bool = true) -> TreeEdit {
        precondition(Int(index) < count && !nodes[Int(index)].flags.contains(.dead), "Knoten \(index) lebt nicht")
        var m = TreeMutator(self, extraNodes: subtree.count, extraNames: subtree.names.count)
        let before = nodes[Int(index)]
        let newIndex = m.replaceSubtree(at: index, with: subtree)
        let after = m.nodes[Int(newIndex)]
        return m.finish(index: newIndex, before: before, after: after, compactIfNeeded: compactIfNeeded)
    }

    /// Entfernt den Knoten `index` samt Teilbaum (z. B. nach „In den
    /// Papierkorb“, SPEC 3.6) und propagiert die Größen bis zur Wurzel.
    /// `TreeEdit.index` ist danach der Elternknoten. Die Wurzel lässt sich
    /// nicht entfernen.
    public func removingNode(at index: Int32, compactIfNeeded: Bool = true) -> TreeEdit {
        precondition(index > 0 && Int(index) < count, "Die Wurzel lässt sich nicht entfernen")
        precondition(!nodes[Int(index)].flags.contains(.dead), "Knoten \(index) lebt nicht")
        var m = TreeMutator(self, extraNodes: 0, extraNames: 0)
        let before = nodes[Int(index)]
        let parent = m.removeNode(at: index)
        var after = before
        after.allocatedSize = 0
        after.logicalSize = 0
        return m.finish(index: parent, before: before, after: after, compactIfNeeded: compactIfNeeded)
    }

    /// Kompaktierte Kopie ohne tote Knoten (Breitensuche-Reihenfolge, Namen
    /// neu gepackt). `TreeEdit.translate` bildet alte auf neue Indizes ab.
    public func compacted() -> TreeEdit {
        let (tree, map) = TreeMutator.compact(nodes: nodes, names: names, hardlinks: hardlinks,
                                              rootPath: rootPath, isComplete: isComplete)
        let root = tree.nodes[0]
        return TreeEdit(tree: tree, index: 0, allocatedBefore: root.allocatedSize, allocatedAfter: root.allocatedSize,
                        logicalBefore: root.logicalSize, logicalAfter: root.logicalSize, compacted: true,
                        relocations: [:], compactionMap: map)
    }
}

/// Arbeitskopie eines Baums für eine Änderung. Hält Knoten, Namen und die
/// Hardlink-Tabelle als veränderbare Arrays und erzeugt am Ende eine neue
/// `ScanTree`-Version.
struct TreeMutator {
    var nodes: [Node]
    var names: [UInt8]
    var links: [HardlinkEntry]
    /// Knotenindex → Position in `links` (wird bei Umsortierungen mitgeführt).
    var linkPos: [Int32: Int] = [:]
    var deadCount: Int
    let rootPath: String
    let isComplete: Bool
    /// Ursprünglicher Index → aktueller Index (nur verschobene Knoten).
    var posOfOriginal: [Int32: Int32] = [:]
    /// Aktueller Index → ursprünglicher Index (nur verschobene Knoten).
    var originalAt: [Int32: Int32] = [:]
    /// (Gerät, Inode) der Hardlink-Gruppen, die neu bereinigt werden müssen.
    var touchedGroups: Set<HardlinkKey> = []

    struct HardlinkKey: Hashable {
        var dev: Int32
        var ino: UInt64
    }

    init(_ tree: ScanTree, extraNodes: Int, extraNames: Int) {
        // Eine einzige Kopie mit passender Kapazität (kein zweites Wachsen).
        var n: [Node] = []
        n.reserveCapacity(tree.nodes.count + extraNodes)
        n.append(contentsOf: tree.nodes)
        var nm: [UInt8] = []
        nm.reserveCapacity(tree.names.count + extraNames)
        nm.append(contentsOf: tree.names)
        nodes = n
        names = nm
        links = tree.hardlinks
        deadCount = tree.deadCount
        rootPath = tree.rootPath
        isComplete = tree.isComplete
        for (p, h) in links.enumerated() { linkPos[h.index] = p }
    }

    // MARK: Grundoperationen

    /// Knoten von `from` nach `to` verschoben: Kinder, Hardlink-Tabelle und
    /// Index-Übersetzung nachführen. `nodes[to]` enthält den Knoten bereits.
    private mutating func didMove(from: Int32, to: Int32) {
        let n = nodes[Int(to)]
        if n.childCount > 0 {
            for c in n.firstChild ..< n.firstChild + n.childCount { nodes[Int(c)].parent = to }
        }
        let orig = originalAt[from] ?? from
        posOfOriginal[orig] = to
        newOriginalAt[to] = orig
        if let p = linkPos[from] {
            movedLinks.append((p, to))
        }
    }

    /// Zwischenspeicher für einen Verschiebe-Durchgang (alle Moves eines
    /// Durchgangs werden gemeinsam übernommen, weil sich Quellen und Ziele
    /// überschneiden).
    private var newOriginalAt: [Int32: Int32] = [:]
    private var movedLinks: [(pos: Int, to: Int32)] = []

    private mutating func beginMoves() {
        newOriginalAt.removeAll(keepingCapacity: true)
        movedLinks.removeAll(keepingCapacity: true)
    }

    private mutating func commitMoves(sources: [Int32]) {
        // Alte Zuordnungen der Quellplätze entfernen, neue übernehmen.
        for s in sources {
            originalAt[s] = nil
            linkPos[s] = nil
        }
        for (to, orig) in newOriginalAt { originalAt[to] = orig }
        for (pos, to) in movedLinks {
            links[pos].index = to
            linkPos[to] = pos
        }
    }

    /// Bringt Knoten `c` innerhalb der Geschwister an die richtige Stelle
    /// (Sortierregel des `TreeBuilder`) und gibt seinen neuen Index zurück.
    @discardableResult
    mutating func reposition(_ c: Int32) -> Int32 {
        let p = nodes[Int(c)].parent
        guard p >= 0 else { return c }
        let first = nodes[Int(p)].firstChild
        let end = first + nodes[Int(p)].childCount
        let rec = nodes[Int(c)]
        var pos = c
        names.withUnsafeBufferPointer { nm in
            while pos > first, TreeBuilder.precedes(rec, nodes[Int(pos - 1)], nm) { pos -= 1 }
            if pos == c {
                while pos < end - 1, TreeBuilder.precedes(nodes[Int(pos + 1)], rec, nm) { pos += 1 }
            }
        }
        guard pos != c else { return c }
        beginMoves()
        var sources: [Int32] = [c]
        if pos < c {
            // Knoten wandert nach vorn, die dazwischen rücken eins nach hinten.
            var i = c
            while i > pos {
                nodes[Int(i)] = nodes[Int(i - 1)]
                sources.append(i - 1)
                didMove(from: i - 1, to: i)
                i -= 1
            }
        } else {
            var i = c
            while i < pos {
                nodes[Int(i)] = nodes[Int(i + 1)]
                sources.append(i + 1)
                didMove(from: i + 1, to: i)
                i += 1
            }
        }
        nodes[Int(pos)] = rec
        didMove(from: c, to: pos)
        commitMoves(sources: sources)
        return pos
    }

    /// Addiert die Differenzen auf alle Vorfahren von `i` und sortiert dann
    /// von `i` aufwärts in jeder Ebene neu. Gibt den neuen Index von `i` zurück.
    mutating func propagate(from i: Int32, dA: UInt64, dL: UInt64, dF: UInt32) -> Int32 {
        var a = nodes[Int(i)].parent
        while a >= 0 {
            nodes[Int(a)].allocatedSize &+= dA
            nodes[Int(a)].logicalSize &+= dL
            nodes[Int(a)].fileCount &+= dF
            a = nodes[Int(a)].parent
        }
        let result = reposition(i)
        var c = nodes[Int(result)].parent
        while c >= 0, nodes[Int(c)].parent >= 0 {
            let moved = reposition(c)
            c = nodes[Int(moved)].parent
        }
        return result
    }

    /// Markiert alle Nachfahren von `i` (ohne `i`) als tot; mit `includeSelf`
    /// auch `i`. Hardlinks darin fliegen aus der Tabelle, ihre Gruppen
    /// werden zur Neubereinigung vorgemerkt.
    mutating func killDescendants(of i: Int32, includeSelf: Bool) {
        var stack: [Int32] = includeSelf ? [i] : Array(childRange(i))
        var removedLinkPositions: [Int] = []
        while let v = stack.popLast() {
            nodes[Int(v)].flags.insert(.dead)
            deadCount += 1
            if let p = linkPos[v] {
                removedLinkPositions.append(p)
                touchedGroups.insert(HardlinkKey(dev: links[p].dev, ino: links[p].ino))
                linkPos[v] = nil
            }
            stack.append(contentsOf: childRange(v))
        }
        if !removedLinkPositions.isEmpty { removeLinks(at: removedLinkPositions) }
    }

    private func childRange(_ i: Int32) -> Range<Int32> {
        let n = nodes[Int(i)]
        return n.firstChild ..< n.firstChild + n.childCount
    }

    private mutating func removeLinks(at positions: [Int]) {
        let drop = Set(positions)
        links = links.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        linkPos.removeAll(keepingCapacity: true)
        for (p, h) in links.enumerated() { linkPos[h.index] = p }
    }

    private mutating func addLink(_ h: HardlinkEntry) {
        linkPos[h.index] = links.count
        links.append(h)
        touchedGroups.insert(HardlinkKey(dev: h.dev, ino: h.ino))
    }

    // MARK: Operationen

    mutating func replaceSubtree(at index: Int32, with sub: ScanTree) -> Int32 {
        let old = nodes[Int(index)]
        killDescendants(of: index, includeSelf: false)
        // Der Knoten bleibt, sein alter Hardlink-Eintrag (war er eine Datei)
        // nicht: Sonst stünde er neben dem neuen Eintrag doppelt in der
        // Tabelle, und die Gruppe zählte gar nicht mehr.
        if let p = linkPos[index] {
            touchedGroups.insert(HardlinkKey(dev: links[p].dev, ino: links[p].ino))
            removeLinks(at: [p])
        }

        // Neue Nachfahren hinten anhängen: Unterbaum-Index j ≥ 1 → base + j.
        let base = Int32(nodes.count) - 1
        let nameBase = UInt32(names.count)
        names.append(contentsOf: sub.names)
        let subRoot = sub.nodes[0]
        for j in 1 ..< sub.nodes.count {
            var n = sub.nodes[j]
            n.parent = n.parent == 0 ? index : n.parent + base
            n.firstChild += base
            n.nameOffset += nameBase
            nodes.append(n)
        }
        // Der Knoten selbst behält Name, Elternknoten und Index.
        var updated = old
        updated.allocatedSize = subRoot.allocatedSize
        updated.logicalSize = subRoot.logicalSize
        updated.fileCount = subRoot.fileCount
        updated.childCount = subRoot.childCount
        updated.firstChild = subRoot.childCount > 0 ? subRoot.firstChild + base : Int32(nodes.count)
        updated.flags = subRoot.flags.subtracting([.hidden, .mountPoint]).union(old.flags.intersection([.hidden]))
        nodes[Int(index)] = updated
        for h in sub.hardlinks {
            var e = h
            e.index = h.index == 0 ? index : h.index + base
            addLink(e)
        }

        var current = propagate(from: index,
                                dA: updated.allocatedSize &- old.allocatedSize,
                                dL: updated.logicalSize &- old.logicalSize,
                                dF: updated.fileCount &- old.fileCount)
        reconcileHardlinks()
        current = posOfOriginal[index] ?? current
        return current
    }

    mutating func removeNode(at index: Int32) -> Int32 {
        let old = nodes[Int(index)]
        let parent = old.parent
        killDescendants(of: index, includeSelf: true)
        // Aus dem Kinderbereich des Elternknotens lösen: ans Ende schieben.
        let first = nodes[Int(parent)].firstChild
        let end = first + nodes[Int(parent)].childCount
        if index < end - 1 {
            beginMoves()
            var sources: [Int32] = [index]
            let rec = nodes[Int(index)]
            var i = index
            while i < end - 1 {
                nodes[Int(i)] = nodes[Int(i + 1)]
                sources.append(i + 1)
                didMove(from: i + 1, to: i)
                i += 1
            }
            nodes[Int(end - 1)] = rec // toter Datensatz außerhalb des Bereichs
            // Auch den toten Datensatz als verschoben vermerken; sonst übersetzt
            // `TreeEdit.translate` den entfernten Index auf das nachgerückte
            // Geschwister statt auf `nil`.
            didMove(from: index, to: end - 1)
            commitMoves(sources: sources)
        }
        nodes[Int(parent)].childCount -= 1
        nodes[Int(parent)].allocatedSize &-= old.allocatedSize
        nodes[Int(parent)].logicalSize &-= old.logicalSize
        nodes[Int(parent)].fileCount &-= old.fileCount
        _ = propagate(from: parent, dA: 0 &- old.allocatedSize, dL: 0 &- old.logicalSize, dF: 0 &- old.fileCount)
        reconcileHardlinks()
        return posOfOriginal[parent] ?? parent
    }

    /// Bereinigt alle vorgemerkten Hardlink-Gruppen neu: Das lebende
    /// Vorkommen mit dem kleinsten Pfad zählt mit seiner echten Größe, die
    /// anderen mit 0 und dem Flag `hardlinkDuplicate`.
    ///
    /// Die Positionen in `links` bleiben dabei stabil; verschiebt das
    /// Umsortieren einen Knoten, wird `links[p].index` nachgeführt.
    mutating func reconcileHardlinks() {
        guard !touchedGroups.isEmpty else { return }
        let groups = touchedGroups
        touchedGroups = []
        var byKey: [HardlinkKey: [Int]] = [:]
        for (p, h) in links.enumerated() {
            let key = HardlinkKey(dev: h.dev, ino: h.ino)
            if groups.contains(key) { byKey[key, default: []].append(p) }
        }
        for (_, members) in byKey {
            // Pfade ändern sich beim Umsortieren nicht, nur Indizes.
            let winner = members.min { pathBytes(links[$0].index).lexicographicallyPrecedes(pathBytes(links[$1].index)) }!
            for p in members {
                let e = links[p]
                let isWinner = p == winner
                let wantA = isWinner ? e.allocated : 0
                let wantL = isWinner ? e.logical : 0
                let i = e.index
                let cur = nodes[Int(i)]
                if isWinner {
                    nodes[Int(i)].flags.remove(.hardlinkDuplicate)
                } else {
                    nodes[Int(i)].flags.insert(.hardlinkDuplicate)
                }
                if cur.allocatedSize == wantA, cur.logicalSize == wantL { continue }
                nodes[Int(i)].allocatedSize = wantA
                nodes[Int(i)].logicalSize = wantL
                _ = propagate(from: i, dA: wantA &- cur.allocatedSize, dL: wantL &- cur.logicalSize, dF: 0)
            }
        }
    }

    /// Pfad relativ zur Wurzel als Bytes.
    func pathBytes(_ index: Int32) -> [UInt8] {
        var comps: [Int32] = []
        var i = index
        while i > 0 { comps.append(i); i = nodes[Int(i)].parent }
        var out: [UInt8] = []
        for c in comps.reversed() {
            let n = nodes[Int(c)]
            out.append(UInt8(ascii: "/"))
            out.append(contentsOf: names[Int(n.nameOffset) ..< Int(n.nameOffset) + Int(n.nameLength)])
        }
        return out
    }

    // MARK: Abschluss

    mutating func finish(index: Int32, before: Node, after: Node, compactIfNeeded: Bool) -> TreeEdit {
        links.sort { $0.index < $1.index }
        let tree = ScanTree(rootPath: rootPath, nodes: nodes, names: names, hardlinks: links,
                            isComplete: isComplete, deadCount: deadCount)
        if compactIfNeeded, tree.needsCompaction {
            let (compactTree, map) = Self.compact(nodes: nodes, names: names, hardlinks: links,
                                                  rootPath: rootPath, isComplete: isComplete)
            return TreeEdit(tree: compactTree, index: map[Int(index)], allocatedBefore: before.allocatedSize,
                            allocatedAfter: after.allocatedSize, logicalBefore: before.logicalSize,
                            logicalAfter: after.logicalSize, compacted: true, relocations: posOfOriginal,
                            compactionMap: map)
        }
        return TreeEdit(tree: tree, index: index, allocatedBefore: before.allocatedSize,
                        allocatedAfter: after.allocatedSize, logicalBefore: before.logicalSize,
                        logicalAfter: after.logicalSize, compacted: false, relocations: posOfOriginal,
                        compactionMap: nil)
    }

    /// Breitensuche über die lebenden Knoten (Kinder sind schon sortiert).
    static func compact(
        nodes: [Node], names: [UInt8], hardlinks: [HardlinkEntry], rootPath: String, isComplete: Bool
    ) -> (ScanTree, [Int32]) {
        var map = [Int32](repeating: -1, count: nodes.count)
        var order: [Int32] = [0]
        order.reserveCapacity(nodes.count)
        var k = 0
        while k < order.count {
            let n = nodes[Int(order[k])]
            if n.childCount > 0 { order.append(contentsOf: n.firstChild ..< n.firstChild + n.childCount) }
            k += 1
        }
        for (newIdx, old) in order.enumerated() { map[Int(old)] = Int32(newIdx) }
        var nameTotal = 0
        for old in order { nameTotal += Int(nodes[Int(old)].nameLength) }
        var newNames: [UInt8] = []
        newNames.reserveCapacity(nameTotal)
        var newNodes: [Node] = []
        newNodes.reserveCapacity(order.count)
        var firstChild: Int32 = 1
        for (newIdx, old) in order.enumerated() {
            var n = nodes[Int(old)]
            n.parent = newIdx == 0 ? -1 : map[Int(n.parent)]
            let off = Int(n.nameOffset)
            n.nameOffset = UInt32(newNames.count)
            newNames.append(contentsOf: names[off ..< off + Int(n.nameLength)])
            n.firstChild = firstChild
            firstChild += n.childCount
            newNodes.append(n)
        }
        var links = hardlinks.compactMap { h -> HardlinkEntry? in
            let i = map[Int(h.index)]
            guard i >= 0 else { return nil }
            var e = h
            e.index = i
            return e
        }
        links.sort { $0.index < $1.index }
        let tree = ScanTree(rootPath: rootPath, nodes: newNodes, names: newNames, hardlinks: links,
                            isComplete: isComplete, deadCount: 0)
        return (tree, map)
    }
}
