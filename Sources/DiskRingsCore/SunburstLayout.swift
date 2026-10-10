import Foundation

/// Einstellungen für die Berechnung des Sunburst-Layouts (SPEC 3.4, 5).
public struct SunburstOptions: Sendable, Hashable {
    /// Erlaubter Bereich der Ringanzahl.
    public static let ringRange: ClosedRange<Int> = 3 ... 10
    public static let defaultRings = 6
    public static let defaultMinAngleDegrees = 0.5
    public static let defaultMaxArcs = 12_000

    /// Anzahl der Ringe um die Mitte (3–10).
    public var maxRings: Int {
        didSet { maxRings = Self.ringRange.clamp(maxRings) }
    }
    /// Segmente unter diesem Winkel (in Grad) werden je Elternknoten zu einem
    /// Sammelsegment „N kleinere Elemente“ zusammengefasst.
    public var minAngleDegrees: Double
    /// Obergrenze für die Anzahl der Arcs. Ein Ring, der sie sprengen würde,
    /// entfällt ganz (der erste Ring wird stattdessen gekürzt).
    public var maxArcs: Int
    public var sizeMode: SizeMode
    /// Segmente der Volume-Wurzel (Systemdaten, löschbar, frei; SPEC 4.1
    /// Punkt 4). Erscheinen nur, wenn der Fokus die Wurzel ist, im ersten Ring
    /// hinter den Ordnern, die Teile der Systemdaten im zweiten Ring.
    public var rootSegments: RootSegments

    public init(
        maxRings: Int = SunburstOptions.defaultRings,
        minAngleDegrees: Double = SunburstOptions.defaultMinAngleDegrees,
        maxArcs: Int = SunburstOptions.defaultMaxArcs,
        sizeMode: SizeMode = .allocated,
        rootSegments: RootSegments = .none
    ) {
        self.maxRings = Self.ringRange.clamp(maxRings)
        self.minAngleDegrees = max(0, minAngleDegrees)
        self.maxArcs = max(1, maxArcs)
        self.sizeMode = sizeMode
        self.rootSegments = rootSegments
    }

    var minAngle: Double { minAngleDegrees * .pi / 180 }
}

extension ClosedRange where Bound: Comparable {
    func clamp(_ v: Bound) -> Bound { Swift.min(Swift.max(v, lowerBound), upperBound) }
}

/// Ein Segment des Diagramms. Winkel im Bogenmaß, 0 = oben (12 Uhr),
/// im Uhrzeigersinn steigend bis 2π.
public struct SunburstArc: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        /// Ein Knoten des Baums (Ordner oder Datei).
        case node
        /// Sammelsegment „N kleinere Elemente“; `nodeIndex` ist der Elternknoten.
        case aggregate
        /// Größe des Elternknotens, die keinem Kind zugeordnet ist (in den
        /// Live-Snapshots: Dateien, die noch nicht als Knoten vorliegen).
        case remainder
        /// „Systemdaten“ an der Volume-Wurzel (andere Volumes, nicht lesbar).
        case system
        /// Ein Teil der Systemdaten im zweiten Ring; `part` ist der Index in
        /// `SunburstOptions.rootSegments.systemParts`.
        case systemPart
        /// „Löschbar“ (purgeable) an der Volume-Wurzel.
        case purgeable
        /// Freier Speicher an der Volume-Wurzel.
        case free

        /// Segment der Volume-Wurzel, das keinem Knoten entspricht.
        public var isVolumeSegment: Bool {
            switch self {
            case .system, .systemPart, .purgeable, .free: true
            case .node, .aggregate, .remainder: false
            }
        }

        /// Stärke der Schraffur (0 = keine): frei deutlich, löschbar leicht,
        /// Systemdaten und Ordner nie.
        public var hatchStrength: Double {
            switch self {
            case .free: 1
            case .purgeable: 0.5
            case .node, .aggregate, .remainder, .system, .systemPart: 0
            }
        }
    }

    public var kind: Kind
    /// Knoten bei `.node`, sonst der Elternknoten.
    public var nodeIndex: Int32
    /// Ring, 1 = innerster Ring um die Mitte.
    public var depth: Int32
    public var startAngle: Double
    public var endAngle: Double
    public var size: UInt64
    /// Anzahl der zusammengefassten Elemente bei `.aggregate`, sonst 1.
    public var itemCount: Int32
    /// Index des Eltern-Arcs in `SunburstLayout.arcs`, -1 im ersten Ring.
    public var parentArc: Int32
    /// Index des Arcs im ersten Ring, zu dessen Ast dieser Arc gehört.
    public var branch: Int32
    public var isDirectory: Bool
    /// Index in `SunburstOptions.rootSegments.systemParts` bei `.systemPart`, sonst -1.
    public var part: Int32 = -1

    public var span: Double { endAngle - startAngle }
    public var midAngle: Double { (startAngle + endAngle) / 2 }
}

/// Berechnetes Sunburst-Layout ab einem Fokusknoten (SPEC 5).
///
/// Die Arcs liegen ringweise hintereinander (erst alle Arcs von Ring 1, dann
/// Ring 2 …) und sind innerhalb eines Rings nach Winkel sortiert; das nutzt der
/// `SunburstHitTester` für die binäre Suche.
public struct SunburstLayout: Sendable {
    public let focus: Int32
    public let options: SunburstOptions
    public let arcs: [SunburstArc]
    /// Bereich in `arcs` je Ring; `ringRanges[0]` ist Ring 1.
    public let ringRanges: [Range<Int>]
    /// Größe des Fokusknotens (ohne Segmente der Volume-Wurzel).
    public let focusSize: UInt64
    /// Größe, die dem vollen Kreis entspricht (mit Systemdaten, löschbar und
    /// frei, falls gezeigt).
    public let totalSize: UInt64

    /// Anzahl der tatsächlich belegten Ringe.
    public var ringCount: Int { ringRanges.count }
    public var isEmpty: Bool { arcs.isEmpty }

    public func arcs(inRing ring: Int) -> ArraySlice<SunburstArc> {
        guard ring >= 1, ring <= ringRanges.count else { return [] }
        return arcs[ringRanges[ring - 1]]
    }

    /// Index des Arcs, der den Knoten zeigt (lineare Suche).
    public func arcIndex(ofNode node: Int32) -> Int? {
        arcs.firstIndex { $0.kind == .node && $0.nodeIndex == node }
    }

    public init(tree: ScanTree, focus: Int32 = ScanTree.rootIndex, options: SunburstOptions = SunburstOptions()) {
        self.focus = focus
        self.options = options
        let mode = options.sizeMode
        let focusSize = tree.node(focus).size(mode)
        let segments = focus == ScanTree.rootIndex ? options.rootSegments : .none
        let (total, overflow) = focusSize.addingReportingOverflow(segments.total)
        self.focusSize = focusSize
        self.totalSize = overflow ? UInt64.max : total
        guard totalSize > 0 else {
            arcs = []
            ringRanges = []
            return
        }

        var builder = LayoutBuilder(tree: tree, options: options)
        let focusSpan = 2 * Double.pi * Double(focusSize) / Double(totalSize)

        // Ring 1: Kinder des Fokus, dahinter Systemdaten, löschbar und frei.
        let extras: [(SunburstArc.Kind, UInt64)] = [(.system, segments.system), (.purgeable, segments.purgeable),
                                                    (.free, segments.free)].filter { $0.1 > 0 }
        var ring1: [SunburstArc] = []
        if focusSize > 0, tree.node(focus).isDirectory {
            builder.expand(parent: focus, parentArc: -1, start: 0, span: focusSpan, depth: 1,
                           branch: nil, budget: options.maxArcs - extras.count, into: &ring1)
        }
        var cum = focusSize
        var systemArc: Int?
        // Bei einer winzigen Arc-Obergrenze (nur in Tests) entfallen hintere Segmente.
        for (n, (kind, size)) in extras.enumerated() where n < options.maxArcs {
            let a0 = 2 * Double.pi * Double(cum) / Double(totalSize)
            cum = cum.addingReportingOverflow(size).overflow ? .max : cum + size
            let a1 = n == extras.count - 1 ? 2 * .pi : min(2 * .pi, 2 * Double.pi * Double(cum) / Double(totalSize))
            if kind == .system { systemArc = ring1.count }
            ring1.append(SunburstArc(kind: kind, nodeIndex: focus, depth: 1, startAngle: a0, endAngle: a1,
                                     size: size, itemCount: 1, parentArc: -1, branch: Int32(ring1.count),
                                     isDirectory: false))
        }
        var arcs = ring1
        var ranges: [Range<Int>] = ring1.isEmpty ? [] : [0 ..< ring1.count]

        // Weitere Ringe in Breitensuche; die Eltern werden in Winkelreihenfolge
        // abgearbeitet, so bleibt jeder Ring nach Winkel sortiert.
        var depth: Int32 = 2
        while Int(depth) <= options.maxRings, let prev = ranges.last {
            var ring: [SunburstArc] = []
            for pi in prev {
                let p = arcs[pi]
                guard p.kind == .node, p.isDirectory, p.size > 0, tree.node(p.nodeIndex).childCount > 0 else { continue }
                builder.expand(parent: p.nodeIndex, parentArc: Int32(pi), start: p.startAngle, span: p.span,
                               depth: depth, branch: p.branch, budget: .max, into: &ring)
            }
            // Teile der Systemdaten im zweiten Ring (der Systemdaten-Arc liegt
            // hinter allen Ordnern, die Reihenfolge nach Winkel bleibt erhalten).
            if depth == 2, let si = systemArc {
                Self.appendSystemParts(segments.systemParts, parent: arcs[si], parentArc: si, into: &ring)
            }
            if ring.isEmpty || arcs.count + ring.count > options.maxArcs { break }
            ranges.append(arcs.count ..< arcs.count + ring.count)
            arcs.append(contentsOf: ring)
            depth += 1
        }
        self.arcs = arcs
        self.ringRanges = ranges
    }

    private static func appendSystemParts(_ parts: [VolumeBreakdown.SystemPart], parent: SunburstArc, parentArc: Int,
                                          into ring: inout [SunburstArc]) {
        guard parent.size > 0 else { return }
        let scale = parent.span / Double(parent.size)
        var cum: UInt64 = 0
        for (i, p) in parts.enumerated() where p.size > 0 {
            let a0 = parent.startAngle + Double(cum) * scale
            cum = min(parent.size, cum + min(p.size, parent.size - cum))
            let a1 = cum == parent.size ? parent.endAngle : min(parent.endAngle, parent.startAngle + Double(cum) * scale)
            guard a1 > a0 else { continue }
            ring.append(SunburstArc(kind: .systemPart, nodeIndex: parent.nodeIndex, depth: 2, startAngle: a0,
                                    endAngle: a1, size: p.size, itemCount: 1, parentArc: Int32(parentArc),
                                    branch: parent.branch, isDirectory: false, part: Int32(i)))
        }
    }

    /// Teil der Systemdaten hinter einem `.systemPart`-Arc.
    public func systemPart(of arc: SunburstArc) -> VolumeBreakdown.SystemPart? {
        guard arc.kind == .systemPart, arc.part >= 0, Int(arc.part) < options.rootSegments.systemParts.count
        else { return nil }
        return options.rootSegments.systemParts[Int(arc.part)]
    }

    /// Titel eines Segments der Volume-Wurzel („Systemdaten“, „Löschbar“ …), sonst `nil`.
    public func volumeSegmentTitle(_ arc: SunburstArc) -> String? {
        switch arc.kind {
        case .system: L("arc.system.title")
        case .systemPart: systemPart(of: arc)?.title
        case .purgeable: L("arc.purgeable.title")
        case .free: L("arc.free.title")
        case .node, .aggregate, .remainder: nil
        }
    }

    /// Erklärung eines Segments der Volume-Wurzel, sonst `nil`.
    public func volumeSegmentDetail(_ arc: SunburstArc, fullDiskAccessDenied: Bool = false) -> String? {
        switch arc.kind {
        case .system: L("arc.system.detail")
        case .systemPart: systemPart(of: arc)?.detail(fullDiskAccessDenied: fullDiskAccessDenied)
        case .purgeable: L("format.sentences", L("arc.purgeable.detail"), L("arc.snapshots.note"))
        case .free: L("arc.free.detail")
        case .node, .aggregate, .remainder: nil
        }
    }
}

/// Hilfsstruktur für die Berechnung der Kind-Arcs eines Elternknotens.
private struct LayoutBuilder {
    let tree: ScanTree
    let nodes: [Node]
    let mode: SizeMode
    let minAngle: Double
    var scratch: [Int32] = []

    init(tree: ScanTree, options: SunburstOptions) {
        self.tree = tree
        self.nodes = tree.nodes
        self.mode = options.sizeMode
        // Kleine relative Toleranz: Ein Element genau auf der Schwelle (z. B. 0,5°) soll
        // trotz Rundung im Gleitkomma einzeln erscheinen (Vergleich ist „>=“).
        self.minAngle = options.minAngle * (1 - 1e-9)
    }

    /// Hängt die Arcs der Kinder von `parent` an `out` an: alle Kinder ab der
    /// Winkelschwelle einzeln (nach Größe absteigend), den Rest als
    /// Sammelsegment. `budget` begrenzt die Zahl der neuen Arcs.
    mutating func expand(
        parent: Int32, parentArc: Int32, start: Double, span: Double, depth: Int32,
        branch: Int32?, budget: Int, into out: inout [SunburstArc]
    ) {
        let pnode = nodes[Int(parent)]
        let psize = pnode.size(mode)
        guard psize > 0, span > 0 else { return }
        let scale = span / Double(psize)
        let first = Int(pnode.firstChild), count = Int(pnode.childCount)

        // Kinder in Anzeige-Reihenfolge, die die Schwelle erreichen. Im Modus
        // „belegt“ sind die Kinder schon passend sortiert; dann genügt es, bis
        // zum ersten zu kleinen Kind zu laufen (O(Arcs) statt O(Kinder)).
        scratch.removeAll(keepingCapacity: true)
        let budget = max(0, budget)
        guard budget > 0 else { return }
        if mode == .allocated {
            var i = first
            while i < first + count, scratch.count < budget {
                let sz = nodes[i].allocatedSize
                if sz == 0 || Double(sz) * scale < minAngle { break }
                scratch.append(Int32(i))
                i += 1
            }
        } else {
            for i in first ..< first + count {
                let sz = nodes[i].logicalSize
                if sz > 0, Double(sz) * scale >= minAngle { scratch.append(Int32(i)) }
            }
            scratch.sort { a, b in
                let sa = nodes[Int(a)].logicalSize, sb = nodes[Int(b)].logicalSize
                return sa != sb ? sa > sb : a < b
            }
            if scratch.count > budget { scratch.removeLast(scratch.count - budget) }
        }
        // Budget voll, aber noch Kinder übrig: Platz für das Sammelsegment schaffen,
        // damit nie mehr als `budget` Arcs entstehen.
        if scratch.count >= budget, count > scratch.count {
            scratch.removeLast()
        }

        // Einzelne Kinder. Bei einem inkonsistenten Baum (Kindersumme größer als
        // der Elternknoten) wird geklemmt: Kein Kind ragt über den Eltern-Arc hinaus.
        let end = start + span
        var cum: UInt64 = 0
        var shown = 0
        for c in scratch {
            if cum >= psize { break }
            let n = nodes[Int(c)]
            let sz = min(n.size(mode), psize - cum)
            let a0 = start + Double(cum) * scale
            cum += sz
            let a1 = cum == psize ? end : min(end, start + Double(cum) * scale)
            let idx = Int32(out.count)
            out.append(SunburstArc(kind: .node, nodeIndex: c, depth: depth, startAngle: a0, endAngle: a1, size: sz,
                                   itemCount: 1, parentArc: parentArc, branch: branch ?? idx,
                                   isDirectory: n.isDirectory))
            shown += 1
        }
        // Rest = Elterngröße − bereits platzierte Kinder (ohne die übrigen Kinder
        // einzeln zu durchlaufen). Gibt es noch Kinder, ist das ein Sammelsegment;
        // es enthält dann auch eine eventuelle Eigengröße des Ordners. Ohne
        // weitere Kinder ist der Rest reine Eigengröße („Dateien in diesem Ordner“,
        // z. B. in Live-Snapshots).
        let restCount = count - shown
        let restSize = psize - cum
        let a0 = start + Double(cum) * scale
        guard restSize > 0, end > a0 else { return }
        let idx = Int32(out.count)
        out.append(SunburstArc(kind: restCount > 0 ? .aggregate : .remainder, nodeIndex: parent, depth: depth,
                               startAngle: a0, endAngle: end, size: restSize,
                               itemCount: Int32(clamping: max(restCount, 1)),
                               parentArc: parentArc, branch: branch ?? idx, isDirectory: false))
    }
}

extension SunburstLayout {
    /// Winkelbereich und Tiefenabstand von `node` im Layout-Raum des Vorfahren
    /// `ancestor` (so, wie `SunburstLayout(tree:focus: ancestor)` ihn zeichnen
    /// würde, ohne Schwellen und Ringgrenzen). `nil`, wenn `ancestor` kein
    /// Vorfahr (oder der Knoten selbst) ist.
    public static func angularSpan(
        of node: Int32, under ancestor: Int32, tree: ScanTree, options: SunburstOptions
    ) -> (start: Double, end: Double, depth: Int)? {
        let nodes = tree.nodes
        var chain: [Int32] = []
        var i = node
        while i != ancestor {
            guard i > 0 else { return nil }
            chain.append(i)
            i = nodes[Int(i)].parent
        }
        let mode = options.sizeMode
        let asize = nodes[Int(ancestor)].size(mode)
        let extra = ancestor == ScanTree.rootIndex ? options.rootSegments.total : 0
        let total = Double(asize) + Double(extra)
        guard total > 0 else { return (0, 0, chain.count) }
        var start = 0.0
        var span = 2 * Double.pi * Double(asize) / total
        for c in chain.reversed() {
            let cn = nodes[Int(c)]
            let pn = nodes[Int(cn.parent)]
            let psize = pn.size(mode)
            guard psize > 0 else { return (start, start, chain.count) }
            let csize = cn.size(mode)
            // Summe der Geschwister, die im Layout vor dem Knoten liegen.
            var preceding: UInt64 = 0
            let first = Int(pn.firstChild)
            if mode == .allocated {
                for s in first ..< Int(c) { preceding &+= nodes[s].allocatedSize }
            } else {
                for s in first ..< first + Int(pn.childCount) where s != Int(c) {
                    let ss = nodes[s].logicalSize
                    if ss > csize || (ss == csize && s < Int(c)) { preceding &+= ss }
                }
            }
            let scale = span / Double(psize)
            start += Double(preceding) * scale
            span = Double(csize) * scale
        }
        return (start, start + span, chain.count)
    }
}
