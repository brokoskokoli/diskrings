/// Auswahl in Liste und Diagramm (SPEC 3.5, 3.6: Mehrfachauswahl in der
/// Liste). Knoten in Auswahlreihenfolge, dazu der Anker für die
/// Bereichsauswahl mit ⇧ und der zuletzt angeklickte Knoten (`primary`).
public struct NodeSelection: Sendable, Equatable {
    /// Ausgewählte Knoten in der Reihenfolge, in der sie hinzukamen.
    public private(set) var nodes: [Int32] = []
    /// Ausgangspunkt einer Bereichsauswahl (⇧-Klick).
    public private(set) var anchor: Int32?

    public init() {}

    public init(_ nodes: [Int32]) {
        for n in nodes where !self.nodes.contains(n) { self.nodes.append(n) }
        anchor = self.nodes.last
    }

    public var isEmpty: Bool { nodes.isEmpty }
    public var count: Int { nodes.count }
    /// Der zuletzt gewählte Knoten (z. B. für die Hervorhebung im Diagramm).
    public var primary: Int32? { nodes.last }
    public func contains(_ node: Int32) -> Bool { nodes.contains(node) }

    /// Einfacher Klick: nur dieser Knoten (oder nichts).
    public mutating func select(_ node: Int32?) {
        nodes = node.map { [$0] } ?? []
        anchor = node
    }

    /// ⌘-Klick: Knoten hinzufügen bzw. entfernen.
    public mutating func toggle(_ node: Int32) {
        if let i = nodes.firstIndex(of: node) {
            nodes.remove(at: i)
            anchor = nodes.last
        } else {
            nodes.append(node)
            anchor = node
        }
    }

    /// ⇧-Klick: alle sichtbaren Zeilen zwischen Anker und `node` (die
    /// Reihenfolge der Liste gibt `visible` vor). Ohne Anker oder wenn der
    /// Anker nicht sichtbar ist, wie ein einfacher Klick.
    public mutating func extend(to node: Int32, visible: [Int32]) {
        guard let a = anchor, let i = visible.firstIndex(of: a), let j = visible.firstIndex(of: node) else {
            select(node)
            return
        }
        let range = i <= j ? Array(visible[i ... j]) : Array(visible[j ... i].reversed())
        nodes = range
        anchor = a
        // `primary` ist der angeklickte Knoten.
        if let k = nodes.firstIndex(of: node) {
            nodes.remove(at: k)
            nodes.append(node)
        }
    }

    /// Überträgt die Auswahl über eine Index-Übersetzung (z. B.
    /// `TreeEdit.translate`); nicht mehr vorhandene Knoten entfallen.
    public func translated(_ map: (Int32) -> Int32?) -> NodeSelection {
        var s = NodeSelection()
        for n in nodes { if let m = map(n), !s.nodes.contains(m) { s.nodes.append(m) } }
        s.anchor = anchor.flatMap(map) ?? s.nodes.last
        return s
    }

    /// Nur die obersten Knoten: Knoten, deren Vorfahr ebenfalls ausgewählt
    /// ist, entfallen (beim Papierkorb wandert der Vorfahr samt Inhalt).
    /// Die Reihenfolge bleibt erhalten.
    public func topLevel(in tree: ScanTree) -> [Int32] {
        let set = Set(nodes)
        return nodes.filter { n in
            var p = tree.node(n).parent
            while p >= 0 {
                if set.contains(p) { return false }
                p = tree.node(p).parent
            }
            return true
        }
    }
}
