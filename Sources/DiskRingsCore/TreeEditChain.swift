/// Mehrere Änderungen hintereinander (z. B. Papierkorb mit Mehrfachauswahl).
/// Die Index-Übersetzung führt alte Indizes durch alle Schritte.
public struct TreeEditChain: Sendable {
    /// Ausgangsbaum.
    public let original: ScanTree
    /// Einzelschritte in Reihenfolge.
    public private(set) var edits: [TreeEdit] = []

    public init(original: ScanTree) {
        self.original = original
    }

    /// Ergebnis nach allen Schritten.
    public var tree: ScanTree { edits.last?.tree ?? original }
    public var isEmpty: Bool { edits.isEmpty }

    public mutating func append(_ edit: TreeEdit) {
        edits.append(edit)
    }

    /// Übersetzt einen Index des Ausgangsbaums in den Ergebnisbaum.
    public func translate(_ oldIndex: Int32) -> Int32? {
        var i = oldIndex
        for e in edits {
            guard let j = e.translate(i) else { return nil }
            i = j
        }
        guard Int(i) < tree.count, !tree.nodes[Int(i)].flags.contains(.dead) else { return nil }
        return i
    }

    /// Summe der Änderungen der belegten Größe aller Schritte.
    public var allocatedDelta: Int64 { edits.reduce(0) { $0 + $1.allocatedDelta } }
}

extension ScanTree {
    /// Entfernt mehrere Knoten samt Teilbäumen (Indizes dieses Baums). Knoten,
    /// die mit einem Vorfahren schon entfernt wurden, und die Wurzel werden
    /// übersprungen.
    public func removingNodes(_ indices: [Int32], compactIfNeeded: Bool = true) -> TreeEditChain {
        var chain = TreeEditChain(original: self)
        for i in indices where i != ScanTree.rootIndex {
            guard let current = chain.translate(i), current != ScanTree.rootIndex else { continue }
            chain.append(chain.tree.removingNode(at: current, compactIfNeeded: compactIfNeeded))
        }
        return chain
    }
}
