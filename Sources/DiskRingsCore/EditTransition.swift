/// Übergang nach einer Änderung am Baum (Papierkorb, Teil-Rescan, Undo):
/// Arcs desselben Knotens wandern von ihrer alten zu ihrer neuen Lage,
/// entfernte Arcs schrumpfen auf ihre Mitte und blenden aus, neue wachsen aus
/// ihrer Mitte heraus und blenden ein (SPEC 3.6/3.8: „Das Diagramm animiert
/// die Änderung“).
///
/// Zugeordnet wird über die Index-Übersetzung der Änderung (`TreeEdit
/// .translate` bzw. `TreeEditChain.translate`): Knoten-Arcs über ihren Knoten,
/// Sammel- und Restsegmente über ihren Elternknoten, „Nicht zugeordnet“
/// direkt.
public struct EditTransition: Sendable {
    public let from: SunburstLayout
    public let to: SunburstLayout
    /// Für jeden Arc in `to`: der passende Arc in `from` oder -1.
    let match: [Int]
    /// Arcs in `from` ohne Gegenstück.
    let orphans: [Int]

    private struct Key: Hashable {
        let kind: UInt8
        let node: Int32
    }

    public init(from: SunburstLayout, to: SunburstLayout, translate: (Int32) -> Int32?) {
        self.from = from
        self.to = to
        var byKey: [Key: Int] = [:]
        for (i, a) in to.arcs.enumerated() {
            byKey[Key(kind: a.kind.rawValue, node: a.kind == .unassigned ? -1 : a.nodeIndex)] = i
        }
        var match = [Int](repeating: -1, count: to.arcs.count)
        var orphans: [Int] = []
        for (i, a) in from.arcs.enumerated() {
            let node: Int32? = a.kind == .unassigned ? -1 : translate(a.nodeIndex)
            if let node, let j = byKey[Key(kind: a.kind.rawValue, node: node)], match[j] < 0 {
                match[j] = i
            } else {
                orphans.append(i)
            }
        }
        self.match = match
        self.orphans = orphans
    }

    /// Anzahl der Arcs mit Gegenstück (für Tests).
    public var matchedCount: Int { match.filter { $0 >= 0 }.count }

    /// Alle sichtbaren Arcs zum Zeitpunkt t (0…1): erst die verschwindenden
    /// alten, dann die neuen.
    public func frame(at t: Double, rings: Int) -> [DisplayArc] {
        let t = min(max(t, 0), 1)
        var out: [DisplayArc] = []
        out.reserveCapacity(to.arcs.count + orphans.count)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        func add(_ target: Bool, _ i: Int, _ s: Double, _ e: Double, _ depth: Double, _ opacity: Double) {
            guard e > s, depth > 0.001, depth - 1 < Double(rings) else { return }
            out.append(DisplayArc(isFromTarget: target, arcIndex: i, startAngle: max(0, s),
                                  endAngle: min(2 * .pi, e), innerBoundary: max(0, depth - 1),
                                  outerBoundary: min(depth, Double(rings)), opacity: opacity))
        }
        if t < 1 {
            for i in orphans {
                let a = from.arcs[i]
                let mid = a.midAngle, half = a.span / 2 * (1 - t)
                add(false, i, mid - half, mid + half, Double(a.depth), 1 - t)
            }
        }
        for (j, b) in to.arcs.enumerated() {
            let i = match[j]
            if i >= 0 {
                let a = from.arcs[i]
                add(true, j, lerp(a.startAngle, b.startAngle), lerp(a.endAngle, b.endAngle),
                    lerp(Double(a.depth), Double(b.depth)), 1)
            } else {
                let mid = b.midAngle, half = b.span / 2 * t
                add(true, j, mid - half, mid + half, Double(b.depth), t)
            }
        }
        return out
    }
}
