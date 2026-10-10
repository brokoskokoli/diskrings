import AppKit
import DiskRingsCore
import SwiftUI

/// Detailliste des fokussierten Ordners (SPEC 3.3): Outline, nach Größe
/// sortiert, mit Prozentbalken; Hover und Auswahl sind mit dem Diagramm
/// synchronisiert. Sie ist die zugängliche Hauptdarstellung (SPEC 5).
struct DetailListView: View {
    let state: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// Höchstzahl der Zeilen je Ebene; der Rest wird zusammengefasst.
    static let rowsPerLevel = 400

    var body: some View {
        if let tree = state.tree, let layout = state.layout {
            let palette = Palette(scheme: state.prefs.paletteScheme, appearance: PaletteAppearance(colorScheme))
            let colors = colorMap(layout: layout, palette: palette)
            VStack(spacing: 0) {
                header(tree)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let rows = rows(tree, layout: layout, palette: palette)
                            let visible = rows.filter { $0.kind == .node }.map(\.node)
                            let rescanning = state.rescanningNodes
                            ForEach(rows) { row in
                                DetailRowView(state: state, tree: tree, row: row, swatch: row.swatch ?? colors[row.node],
                                              visibleNodes: visible, rescanProgress: rescanning[row.node])
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.scrollRequest) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(DetailRow.ID.node(target), anchor: .center) }
                        state.scrollRequest = nil
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("list.accessibility", tree.name(of: state.focus)))
        } else {
            Color.clear
        }
    }

    private func header(_ tree: ScanTree) -> some View {
        let focus = tree[state.focus]
        let title = state.focus == ScanTree.rootIndex && state.isVolumeRoot ? (state.volume?.name ?? focus.name) : focus.name
        let size = focus.size(state.prefs.sizeMode)
        let rootSize = tree.root.size(state.prefs.sizeMode)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: focus.symbolName).foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 4) {
                Text(ByteFormat.string(size)).monospacedDigit()
                if state.focus != ScanTree.rootIndex, rootSize > 0 {
                    Text("·")
                    Text(L("list.shareOfRoot", ByteFormat.percent(Double(size) / Double(rootSize))))
                }
            }
            .font(.subheadline)
            Text(filesText(focus.fileCount)).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// Farbe je Knoten aus dem Diagramm (kleines Farbfeld in der Liste).
    private func colorMap(layout: SunburstLayout, palette: Palette) -> [Int32: Color] {
        let colors = state.colors(for: layout, palette: palette)
        var m: [Int32: Color] = [:]
        for (i, a) in layout.arcs.enumerated() where a.kind == .node && a.depth <= 3 { m[a.nodeIndex] = Color(colors[i]) }
        return m
    }

    /// Sichtbare Zeilen: Kinder des Fokus, aufgeklappte Ordner rekursiv.
    /// Alle Anteile beziehen sich auf dieselbe Größe wie das Diagramm
    /// (`layout.totalSize`: der Fokus, an der Volume-Wurzel samt Systemdaten,
    /// löschbar und frei), damit sich die oberste Ebene zu 100 % summiert.
    private func rows(_ tree: ScanTree, layout: SunburstLayout, palette: Palette) -> [DetailRow] {
        let total = Double(max(layout.totalSize, 1))
        var out: [DetailRow] = []
        let mode = state.prefs.sizeMode
        func add(_ parent: Int32, level: Int) {
            var kids = Array(tree.childIndices(of: parent))
            if mode == .logical {
                kids.sort { tree.node($0).logicalSize > tree.node($1).logicalSize }
            }
            for (n, k) in kids.enumerated() {
                if n == Self.rowsPerLevel {
                    let rest = kids[n...].reduce(UInt64(0)) { $0 + tree.node($1).size(mode) }
                    out.append(DetailRow(kind: .more(parent: parent, count: kids.count - n), node: k, level: level,
                                         size: rest, share: Double(rest) / total))
                    break
                }
                let s = tree.node(k).size(mode)
                out.append(DetailRow(kind: .node, node: k, level: level, size: s, share: Double(s) / total))
                if state.expanded.contains(k) { add(k, level: level + 1) }
            }
        }
        add(state.focus, level: 0)
        // Segmente der Volume-Wurzel (Systemdaten mit Teilen, löschbar, frei)
        // aus dem Layout, nach Größe in die oberste Ebene einsortiert.
        for (i, arc) in layout.arcs.enumerated() where arc.depth == 1 && arc.kind.isVolumeSegment {
            var group = [segmentRow(layout, arc, level: 0, total: total, palette: palette)]
            if arc.kind == .system {
                for p in layout.arcs(inRing: 2) where p.kind == .systemPart && p.parentArc == Int32(i) {
                    group.append(segmentRow(layout, p, level: 1, total: total, palette: palette))
                }
            }
            let pos = out.firstIndex { $0.level == 0 && $0.size < arc.size } ?? out.count
            out.insert(contentsOf: group, at: pos)
        }
        return out
    }

    private func segmentRow(_ layout: SunburstLayout, _ arc: SunburstArc, level: Int, total: Double,
                            palette: Palette) -> DetailRow {
        DetailRow(kind: .segment(arc.kind, part: Int(arc.part), title: layout.volumeSegmentTitle(arc) ?? "",
                                 help: layout.volumeSegmentDetail(arc, fullDiskAccessDenied: state.fullDiskAccess == .denied) ?? ""),
                  node: -1, level: level, size: arc.size, share: Double(arc.size) / total,
                  swatch: Color(palette.volumeSegmentFill(arc)))
    }
}

struct DetailRow: Identifiable {
    enum Kind: Equatable {
        case node, more(parent: Int32, count: Int)
        /// Segment der Volume-Wurzel (Systemdaten, ein Teil davon, löschbar, frei).
        case segment(SunburstArc.Kind, part: Int, title: String, help: String)
    }
    enum ID: Hashable { case node(Int32), more(Int32), segment(UInt8, Int) }

    let kind: Kind
    let node: Int32
    let level: Int
    let size: UInt64
    let share: Double
    var swatch: Color?

    /// Erklärung eines Segments der Volume-Wurzel (Tooltip), sonst `nil`.
    var segmentHelp: String? {
        if case .segment(_, _, _, let help) = kind { return help }
        return nil
    }

    var id: ID {
        switch kind {
        case .node: .node(node)
        case .more(let p, _): .more(p)
        case .segment(let k, let part, _, _): .segment(k.rawValue, part)
        }
    }
}

private struct DetailRowView: View {
    let state: AppState
    let tree: ScanTree
    let row: DetailRow
    let swatch: Color?
    /// Knoten der sichtbaren Zeilen in Listenreihenfolge (für ⇧-Klick).
    let visibleNodes: [Int32]
    /// Laufender Teil-Rescan dieser Zeile (-1 = unbestimmt).
    let rescanProgress: Double?

    var body: some View {
        let isSelected = row.kind == .node && state.selection.contains(row.node)
        let isHovered = row.kind == .node && state.hoverNode == row.node
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.level) * 14, height: 1)
            disclosure
            icon
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.kind == .node ? .primary : .secondary)
                // Der Name bekommt den Platz zuerst (sonst kürzt das HStack ihn
                // in der verstellbaren Liste auf wenige Zeichen).
                .layoutPriority(1)
            Spacer(minLength: 8)
            ShareBar(share: row.share, color: swatch ?? Color.secondary.opacity(0.6))
                .frame(width: 54, height: 6)
            Text(ByteFormat.percent(row.share))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if let p = rescanProgress {
                Group {
                    if p >= 0 { ProgressView(value: p).progressViewStyle(.circular) } else { ProgressView() }
                }
                .controlSize(.mini)
                .frame(width: 72, alignment: .trailing)
                .help(L("reason.rescanRunning"))
                .accessibilityLabel(L("reason.rescanRunning"))
            } else {
                Text(ByteFormat.string(row.size))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.07) : .clear))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if row.kind == .node { state.hoverList(inside ? row.node : (state.hoverNode == row.node ? nil : state.hoverNode)) }
        }
        // Nur ein Klick-Handler: ein zusätzlicher Doppelklick-Handler würde jeden
        // Einzelklick verzögern. Der Doppelklick wird über `clickCount` erkannt.
        .onTapGesture {
            guard row.kind == .node else { return }
            let event = NSApp.currentEvent
            if (event?.clickCount ?? 1) >= 2 {
                // Doppelklick: Ordner hineinzoomen, Datei in Quick Look (SPEC 3.4/3.5).
                if tree.node(row.node).isDirectory {
                    state.navigate(to: row.node)
                } else {
                    state.selection.select(row.node)
                    state.perform(.quickLook, targets: [row.node])
                }
                return
            }
            let mods = event?.modifierFlags ?? []
            if mods.contains(.command) {
                state.selection.toggle(row.node)
            } else if mods.contains(.shift) {
                state.selection.extend(to: row.node, visible: visibleNodes)
            } else {
                activate()
            }
        }
        .contextMenu {
            if row.kind == .node {
                NodeContextMenu(state: state, node: row.node)
            } else if case .segment(_, _, let title, let help) = row.kind {
                VolumeSegmentMenu(state: state, title: title, size: row.size, detail: help)
            }
        }
        .help(row.segmentHelp ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("list.row.accessibility", title, ByteFormat.string(row.size), ByteFormat.percent(row.share)))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: L("accessibility.zoomIn")) { if row.kind == .node { state.navigate(to: row.node) } }
    }

    private var isExpandable: Bool { row.kind == .node && tree.node(row.node).childCount > 0 }

    @ViewBuilder private var disclosure: some View {
        if isExpandable {
            let open = state.expanded.contains(row.node)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.kind {
        case .node:
            let n = tree[row.node]
            Image(systemName: n.symbolName)
                .foregroundStyle(n.isDirectory ? AnyShapeStyle(swatch ?? Color.secondary) : AnyShapeStyle(.secondary))
                .frame(width: 16)
        case .more:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 16)
        case .segment(let kind, _, _, _):
            Image(systemName: Self.segmentSymbol(kind)).foregroundStyle(kind == .free ? Color.secondary : (swatch ?? Color.secondary)).frame(width: 16)
        }
    }

    /// SF-Symbol eines Segments der Volume-Wurzel.
    static func segmentSymbol(_ kind: SunburstArc.Kind) -> String {
        switch kind {
        case .system: "gearshape.fill"
        case .systemPart: "internaldrive"
        case .purgeable: "arrow.3.trianglepath"
        case .free: "circle.dashed"
        case .node, .aggregate, .remainder: "questionmark.square.dashed"
        }
    }

    private var title: String {
        switch row.kind {
        case .node: tree.name(of: row.node)
        case .more(_, let count): itemsText(count)
        case .segment(_, _, let title, _): title
        }
    }

    private func toggle() {
        if state.expanded.contains(row.node) { state.expanded.remove(row.node) } else { state.expanded.insert(row.node) }
    }

    private func activate() {
        guard row.kind == .node else { return }
        state.selection.select(row.node)
        if isExpandable { toggle() }
    }
}

/// Prozentbalken.
struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(share > 0 ? 2 : 0, g.size.width * min(max(share, 0), 1)))
            }
        }
        .accessibilityHidden(true)
    }
}
