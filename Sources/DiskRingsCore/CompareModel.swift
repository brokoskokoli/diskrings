import Foundation

/// Darstellung des Diagramms im Vergleichsmodus (SPEC 3.9).
public enum CompareViewMode: String, Sendable, CaseIterable, Identifiable {
    /// Sunburst „Wachstum“: Segmentgröße = positiver Zuwachs.
    case growth
    /// Normale Ansicht mit Delta-Färbung (entfernte Elemente mit alter Größe).
    case delta

    public var id: Self { self }

    public var title: String {
        switch self {
        case .growth: L("compare.mode.growth")
        case .delta: L("compare.mode.delta")
        }
    }
}

extension DiffStatus {
    /// Bezeichnung für Liste und Tooltip.
    public var label: String {
        switch self {
        case .added: L("diff.added")
        case .removed: L("diff.removed")
        case .grown: L("diff.grown")
        case .shrunk: L("diff.shrunk")
        case .unchanged: L("diff.unchanged")
        }
    }
}

/// Ein Baum, den der Sunburst im Vergleichsmodus zeichnet, samt Abbildung
/// Baumknoten ↔ Vergleichseintrag (`SnapshotDiff.entries`).
public struct CompareDisplayTree: Sendable {
    public let tree: ScanTree
    private let entryForNode: [Int32]
    private let nodeForEntry: [Int32]

    init(tree: ScanTree, entryForNode: [Int32], entryCount: Int) {
        self.tree = tree
        self.entryForNode = entryForNode
        var inverse = [Int32](repeating: -1, count: entryCount)
        for (node, e) in entryForNode.enumerated() where e >= 0 && Int(e) < entryCount {
            inverse[Int(e)] = Int32(node)
        }
        nodeForEntry = inverse
    }

    /// Vergleichseintrag eines Baumknotens.
    public func entry(ofNode node: Int32) -> Int32 { entryForNode[Int(node)] }

    /// Baumknoten eines Vergleichseintrags; `nil`, wenn er in diesem Baum fehlt
    /// (z. B. im Wachstumsbaum ohne Zuwachs).
    public func node(forEntry e: Int32) -> Int32? {
        guard e >= 0, Int(e) < nodeForEntry.count else { return nil }
        let n = nodeForEntry[Int(e)]
        return n >= 0 ? n : nil
    }
}

/// Sortierung der Detailliste im Vergleichsmodus (Spalten Name, Vorher,
/// Jetzt, Δ; SPEC 3.9).
public struct CompareSort: Sendable, Equatable {
    public enum Key: Sendable, Equatable, CaseIterable { case name, before, now, delta }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// Standard im Vergleichsmodus: größter Zuwachs zuerst.
    public static let byDeltaDescending = CompareSort(key: .delta, ascending: false)

    /// Klick auf eine Spaltenüberschrift: dieselbe Spalte dreht die Richtung,
    /// eine neue beginnt bei Namen aufsteigend, bei Größen absteigend.
    public mutating func toggle(_ k: Key) {
        if k == key {
            ascending.toggle()
        } else {
            key = k
            ascending = k == .name
        }
    }
}

/// Logik des Vergleichsmodus ohne Oberfläche (SPEC 3.9): Anzeigebäume für
/// beide Diagramm-Varianten, Abbildung von Arcs und Hit-Tests auf
/// Vergleichseinträge, Delta-Farben, Sortierung der Liste und Navigation.
///
/// Der Fokus wird als **Vergleichseintrag** geführt; so bleibt er beim
/// Umschalten zwischen „Wachstum“ und „Delta-Färbung“ erhalten. Fehlt der
/// Eintrag im gezeigten Baum (kein Zuwachs), zeigt das Diagramm den nächsten
/// vorhandenen Vorfahren.
public final class CompareModel: Sendable {
    public let diff: SnapshotDiff
    public let mode: SizeMode
    /// Wachstumsbaum: Größen = Brutto-Zuwachs (`SnapshotDiff.growthTree`).
    public let growth: CompareDisplayTree
    /// Vergleichsbaum für die Delta-Färbung: bestehende Knoten mit neuer
    /// Größe, entfernte mit ihrer alten Größe (damit sie sichtbar bleiben).
    public let union: CompareDisplayTree

    public init(diff: SnapshotDiff, mode: SizeMode = .allocated) {
        self.diff = diff
        self.mode = mode
        let (g, map) = diff.growthTree(mode: mode)
        growth = CompareDisplayTree(tree: g, entryForNode: map, entryCount: diff.count)
        union = Self.unionTree(diff)
    }

    public func displayTree(_ view: CompareViewMode) -> CompareDisplayTree {
        view == .growth ? growth : union
    }

    /// Gibt es überhaupt Zuwachs? Sonst ist der Wachstums-Sunburst leer.
    public var hasGrowth: Bool { growth.tree.root.size(mode) > 0 }

    public var warningTexts: [String] { diff.warnings.map(\.description) }

    // MARK: Diagramm

    /// Fokusknoten im Anzeigebaum: der Eintrag selbst, wenn er dort als Ordner
    /// vorkommt, sonst der nächste vorhandene Vorfahr (Dateien → Elternordner).
    public func displayFocus(forEntry e: Int32, in view: CompareViewMode) -> Int32 {
        let d = displayTree(view)
        var cur = e
        while cur >= 0 {
            if let n = d.node(forEntry: cur), d.tree.node(n).isDirectory { return n }
            cur = diff.entries[Int(cur)].parent
        }
        return ScanTree.rootIndex
    }

    /// Sunburst-Layout ab dem Fokus-Eintrag. „Nicht zugeordnet“ gibt es im
    /// Vergleichsmodus nicht (es ist ein Wert des Volumes, kein Teilbaum).
    public func layout(_ view: CompareViewMode, focusEntry: Int32, options: SunburstOptions) -> SunburstLayout {
        var o = options
        o.unassigned = 0
        o.sizeMode = mode
        return SunburstLayout(tree: displayTree(view).tree, focus: displayFocus(forEntry: focusEntry, in: view), options: o)
    }

    /// Vergleichseintrag eines Arcs (nur bei Knoten-Arcs).
    public func entry(for arc: SunburstArc, view: CompareViewMode) -> Int32? {
        guard arc.kind == .node else { return nil }
        let e = displayTree(view).entry(ofNode: arc.nodeIndex)
        return e >= 0 ? e : nil
    }

    /// Vergleichseintrag zu einem Hit-Test-Ergebnis.
    public func entry(at hit: SunburstHit, layout: SunburstLayout, view: CompareViewMode) -> Int32? {
        guard case .arc(let i) = hit, i >= 0, i < layout.arcs.count else { return nil }
        return entry(for: layout.arcs[i], view: view)
    }

    /// Status des Elements hinter einem Arc (nur Knoten-Arcs).
    public func status(of arc: SunburstArc, view: CompareViewMode) -> DiffStatus? {
        entry(for: arc, view: view).map { diff.status($0, mode) }
    }

    /// Intensitätsskala: Referenz ist die größte Änderung im ersten Ring
    /// (ohne Knoten-Arcs dort: im ganzen Layout).
    public func deltaScale(for layout: SunburstLayout, view: CompareViewMode) -> DeltaScale {
        func maxDelta<S: Sequence>(_ arcs: S) -> UInt64 where S.Element == SunburstArc {
            var m: UInt64 = 0
            for a in arcs { if let e = entry(for: a, view: view) { m = max(m, diff.delta(e, mode).magnitude) } }
            return m
        }
        let ring1 = maxDelta(layout.arcs(inRing: 1))
        return DeltaScale(reference: ring1 > 0 ? ring1 : maxDelta(layout.arcs))
    }

    /// Farben aller Arcs. „Wachstum“ nutzt das normale Farbschema auf dem
    /// Wachstumsbaum, „Delta-Färbung“ Rot/Grün nach Status und Intensität.
    public func colors(for layout: SunburstLayout, view: CompareViewMode, palette: Palette) -> [RGBColor] {
        if view == .growth { return palette.colors(for: layout, tree: growth.tree) }
        let scale = deltaScale(for: layout, view: view)
        return layout.arcs.map { arc in
            switch arc.kind {
            case .node:
                guard let e = entry(for: arc, view: view) else { return palette.aggregateFill }
                return palette.deltaColor(status: diff.status(e, mode), intensity: scale.intensity(diff.delta(e, mode)))
            case .aggregate: return palette.aggregateFill
            case .remainder: return palette.remainderFill
            case .unassigned: return palette.unassignedFill
            }
        }
    }

    // MARK: Liste und Navigation

    /// Kinder eines Eintrags (einschließlich entfernter), sortiert. Bei
    /// Gleichstand entscheidet der Name (aufsteigend).
    public func children(of e: Int32, sortedBy sort: CompareSort) -> [Int32] {
        let kids = Array(diff.childEntries(of: e))
        let names = Dictionary(uniqueKeysWithValues: kids.map { ($0, diff.name(of: $0)) })
        func byName(_ a: Int32, _ b: Int32) -> Bool {
            let r = names[a]!.localizedStandardCompare(names[b]!)
            return r != .orderedSame ? r == .orderedAscending : a < b
        }
        func value(_ x: Int32) -> Int64 {
            switch sort.key {
            case .before: Int64(clamping: diff.oldSize(x, mode))
            case .now: Int64(clamping: diff.newSize(x, mode))
            case .delta: diff.delta(x, mode)
            case .name: 0
            }
        }
        if sort.key == .name { return kids.sorted { sort.ascending ? byName($0, $1) : byName($1, $0) } }
        let values = Dictionary(uniqueKeysWithValues: kids.map { ($0, value($0)) })
        return kids.sorted { a, b in
            let va = values[a]!, vb = values[b]!
            if va != vb { return sort.ascending ? va < vb : va > vb }
            return byName(a, b)
        }
    }

    public func parent(of e: Int32) -> Int32? {
        let p = diff.entries[Int(e)].parent
        return p >= 0 ? p : nil
    }

    /// Einträge von der Wurzel bis `e` (einschließlich), für die Breadcrumb.
    public func ancestors(of e: Int32) -> [Int32] {
        var out: [Int32] = []
        var cur = e
        while cur >= 0 {
            out.append(cur)
            cur = diff.entries[Int(cur)].parent
        }
        return out.reversed()
    }

    /// Ist `ancestor` ein Vorfahr von `e` (oder `e` selbst)?
    public func isAncestor(_ ancestor: Int32, of e: Int32) -> Bool {
        var cur = e
        while cur >= 0 {
            if cur == ancestor { return true }
            cur = diff.entries[Int(cur)].parent
        }
        return false
    }

    /// Tab „Größte Veränderungen“ (Top 50, tiefster aussagekräftiger Knoten).
    public func largestChanges(growth: Bool = true, limit: Int = 50) -> [DiffChange] {
        diff.largestChanges(limit: limit, growth: growth, mode: mode)
    }

    // MARK: Vergleichsbaum

    /// Baut den Vereinigungsbaum: Größe eines bestehenden Eintrags = neue
    /// Größe plus alte Größe der darin entfernten Teilbäume; ein entfernter
    /// Eintrag hat seine alte Größe. So erfüllt jeder Ordner die Invariante
    /// „mindestens die Summe der Kinder“, und die Winkel der bestehenden
    /// Elemente entsprechen (bis auf entfernte Geschwister) der normalen Ansicht.
    static func unionTree(_ diff: SnapshotDiff) -> CompareDisplayTree {
        let entries = diff.entries
        let n = entries.count
        func base(_ e: Int32, _ m: SizeMode) -> UInt64 {
            entries[Int(e)].newIndex >= 0 ? diff.newSize(e, m) : diff.oldSize(e, m)
        }
        // Eigengröße = Basisgröße − Summe der Basisgrößen der Kinder, die zur
        // selben Seite gehören (bestehend bzw. entfernt). Entfernte Kinder
        // eines bestehenden Ordners kommen über ihren eigenen Teilbaum dazu.
        var raw = RawTree()
        raw.reserve(n, nameBytes: diff.new.tree.names.count)
        for e in 0 ..< n {
            let ei = Int32(e)
            let entry = entries[e]
            let removed = entry.newIndex < 0
            var childA: UInt64 = 0, childL: UInt64 = 0
            for c in diff.childEntries(of: ei) where (entries[Int(c)].newIndex < 0) == removed {
                childA &+= base(c, .allocated)
                childL &+= base(c, .logical)
            }
            let a = base(ei, .allocated), l = base(ei, .logical)
            let own = (a > childA ? a - childA : 0, l > childL ? l - childL : 0)
            let (tree, idx) = removed ? (diff.old.tree, entry.oldIndex) : (diff.new.tree, entry.newIndex)
            let node = tree.nodes[Int(idx)]
            raw.append(parent: entry.parent, name: Array(tree.nameBytes(of: idx)),
                       flags: node.flags.subtracting(.dead), allocated: own.0, logical: own.1,
                       ownFiles: node.isDirectory ? 0 : 1)
        }
        var map = [Int32](repeating: -1, count: n)
        // Ohne Abbruch-Callback kann der Aufbau nicht fehlschlagen.
        // swiftlint:disable:next force_try
        let tree = try! TreeBuilder.build(raw, rootPath: diff.new.tree.rootPath, indexMap: { newIndex in
            for r in 0 ..< n { map[Int(newIndex[r])] = Int32(r) }
        })
        return CompareDisplayTree(tree: tree, entryForNode: map, entryCount: n)
    }
}

/// Kopfzeile des Vergleichsmodus (SPEC 3.9), z. B. „Since 10/02, 9:14 AM:
/// used +38.2 GB · free −38.2 GB · of which unassigned +4.1 GB“.
///
/// - Volume-Wurzel auf beiden Seiten: belegt, frei, davon nicht zugeordnet.
/// - Ordner-Scan: zuerst die Änderung des Ordners (Scan-Summe), dann belegt
///   und frei des Volumes, weil „belegt“ dort das ganze Volume meint.
/// - Ohne Volume-Kennzahlen nur die Scan-Summe.
public struct CompareHeadline: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public let label: String
        public let delta: Int64
        /// Schlüssel der Formatvorlage („compare.part.used“: „used %@“).
        let format: String
        /// Formatierter Wert, z. B. „+38.2 GB“.
        public var text: String { ByteFormat.signed(delta) }
        /// Bezeichnung mit Wert, z. B. „used +38.2 GB“.
        public var labeledText: String {
            format == "compare.part.folder" ? L(format, label, text) : L(format, text)
        }

        init(_ format: String, label: String, delta: Int64) {
            self.format = format
            self.label = label
            self.delta = delta
        }
    }

    /// „Since 10/02, 9:14 AM“ bzw. „From 10/02, 9:14 AM to 10/09, 5:20 PM“.
    public let prefix: String
    public let parts: [Part]

    public var text: String { TextFormat.labeled(prefix, TextFormat.inline(parts.map(\.labeledText))) }

    public init(diff: SnapshotDiff, comparesSnapshots: Bool, timeZone: TimeZone = .current) {
        let s = diff.summary
        let from = Self.shortDate(s.oldDate, timeZone: timeZone)
        prefix = comparesSnapshots ? L("compare.fromTo", from, Self.shortDate(s.newDate, timeZone: timeZone))
            : L("compare.since", from)
        var p: [Part] = []
        if let u = s.unassignedDelta, let used = s.usedDelta, let free = s.freeDelta {
            p = [Part("compare.part.used", label: L("compare.label.used"), delta: used),
                 Part("compare.part.free", label: L("compare.label.free"), delta: free),
                 Part("compare.part.unassigned", label: L("compare.label.unassigned"), delta: u)]
        } else {
            p.append(Part("compare.part.folder", label: diff.name(of: 0), delta: s.scanDelta))
            if let used = s.usedDelta {
                p.append(Part("compare.part.volumeUsed", label: L("compare.label.volumeUsed"), delta: used))
            }
            if let free = s.freeDelta { p.append(Part("compare.part.free", label: L("compare.label.free"), delta: free)) }
        }
        parts = p
    }

    /// Tag, Monat und Uhrzeit im Stil des Locales (de „02.10., 09:14“, en „10/02, 9:14 AM“).
    public static func shortDate(_ date: Date, timeZone: TimeZone = .current, locale: Locale = L10n.locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("ddMMjjmm")
        return f.string(from: date)
    }
}
