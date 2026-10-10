import AppKit
import DiskRingsCore
import SwiftUI

/// Detailliste des fokussierten Ordners (SPEC 3.3): Outline, nach Größe
/// sortiert, mit Prozentbalken; Hover und Auswahl sind mit dem Diagramm
/// synchronisiert. Sie ist die zugängliche Hauptdarstellung (SPEC 5).
struct DetailListView: View {
    let state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

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
                    let rows = rows(tree, base: layout.totalSize)
                    let visible = rows.filter { $0.kind == .node }.map(\.node)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let rescanning = state.rescanningNodes
                            ForEach(rows) { row in
                                DetailRowView(state: state, tree: tree, row: row, swatch: colors[row.node],
                                              visibleNodes: visible, rescanProgress: rescanning[row.node],
                                              listFocused: focused, focusList: { focused = true })
                                    .id(row.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        handleKey(press, rows: rows, tree: tree, visible: visible, proxy: proxy)
                    }
                    .onChange(of: state.scrollRequest) { _, target in
                        guard let target else { return }
                        if reduceMotion {
                            proxy.scrollTo(DetailRow.ID.node(target), anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(DetailRow.ID.node(target), anchor: .center) }
                        }
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

    /// Tastatur (SPEC 5): ↑/↓ (mit ⇧ erweitern), →/← auf-/zuklappen bzw.
    /// Kind/Elternordner, Pos1/Ende, Bild↑/↓, ⏎ zoomt in den Ordner.
    private func handleKey(_ press: KeyPress, rows: [DetailRow], tree: ScanTree, visible: [Int32],
                           proxy: ScrollViewProxy) -> KeyPress.Result {
        let current = state.selection.primary.map { DetailRow.ID.node($0) }
        if OutlineKeyboard.isReturn(press) {
            guard let n = state.selection.primary, tree.node(n).isDirectory else { return .ignored }
            state.navigate(to: n)
            return .handled
        }
        guard let key = OutlineKeyboard.key(press) else { return .ignored }
        let outline = rows.map { r in
            OutlineRow(id: r.id, level: r.level, isSelectable: r.kind == .node,
                       isExpandable: r.kind == .node && tree.node(r.node).childCount > 0,
                       isExpanded: r.kind == .node && state.expanded.contains(r.node))
        }
        switch OutlineNavigation.command(for: key, current: current, rows: outline) {
        case .select(let id):
            guard case .node(let n) = id else { return .handled }
            if press.modifiers.contains(.shift), key == .up || key == .down {
                state.selection.extend(to: n, visible: visible)
            } else {
                state.selection.select(n)
            }
            proxy.scrollTo(id)
        case .expand(let id):
            if case .node(let n) = id { state.expanded.insert(n) }
        case .collapse(let id):
            if case .node(let n) = id { state.expanded.remove(n) }
        case .none:
            break
        }
        return .handled
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
                    Text(TextFormat.inlineSeparatorGlyph)
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
    /// (`layout.totalSize`: der Fokus, an der Volume-Wurzel samt „Nicht
    /// zugeordnet“), damit sich die oberste Ebene zu 100 % summiert.
    private func rows(_ tree: ScanTree, base: UInt64) -> [DetailRow] {
        let total = Double(max(base, 1))
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
        if state.focus == ScanTree.rootIndex, state.unassigned > 0, mode == .allocated {
            let row = DetailRow(kind: .unassigned, node: -1, level: 0, size: state.unassigned,
                                share: Double(state.unassigned) / total)
            // Nach Größe in die oberste Ebene einsortieren.
            let pos = out.firstIndex { $0.level == 0 && $0.size < state.unassigned } ?? out.count
            out.insert(row, at: pos)
        }
        return out
    }
}

struct DetailRow: Identifiable {
    enum Kind: Equatable { case node, more(parent: Int32, count: Int), unassigned }
    enum ID: Hashable { case node(Int32), more(Int32), unassigned }

    let kind: Kind
    let node: Int32
    let level: Int
    let size: UInt64
    let share: Double

    var id: ID {
        switch kind {
        case .node: .node(node)
        case .more(let p, _): .more(p)
        case .unassigned: .unassigned
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
    /// Die Liste hat den Tastaturfokus.
    let listFocused: Bool
    let focusList: () -> Void

    // Spaltenbreiten wachsen mit der Textgröße.
    @ScaledMetric(relativeTo: .callout) private var indent: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var percentWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .callout) private var sizeWidth: CGFloat = 72
    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = 24

    var body: some View {
        let isSelected = row.kind == .node && state.selection.contains(row.node)
        let isHovered = row.kind == .node && state.hoverNode == row.node
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.level) * indent, height: 1)
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
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: percentWidth, alignment: .trailing)
            if let p = rescanProgress {
                Group {
                    if p >= 0 { ProgressView(value: p).progressViewStyle(.circular) } else { ProgressView() }
                }
                .controlSize(.mini)
                .frame(width: sizeWidth, alignment: .trailing)
                .help(L("reason.rescanRunning"))
                .accessibilityLabel(L("reason.rescanRunning"))
            } else {
                Text(ByteFormat.string(row.size))
                    .monospacedDigit()
                    .frame(width: sizeWidth, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(OutlineKeyboard.rowBackground(selected: isSelected, hovered: isHovered, listFocused: listFocused))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if row.kind == .node { state.hoverList(inside ? row.node : (state.hoverNode == row.node ? nil : state.hoverNode)) }
        }
        // Nur ein Klick-Handler: ein zusätzlicher Doppelklick-Handler würde jeden
        // Einzelklick verzögern. Der Doppelklick wird über `clickCount` erkannt.
        .onTapGesture {
            focusList()
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
        .contextMenu { if row.kind == .node { NodeContextMenu(state: state, node: row.node) } }
        .help(row.kind == .unassigned ? L("list.unassigned.help") : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("list.row.accessibility", title, ByteFormat.string(row.size), ByteFormat.percent(row.share)))
        .accessibilityValue(row.kind == .node
            ? OutlineAccessibility.value(level: row.level, isExpandable: isExpandable, isExpanded: isExpanded) : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { activate() }
        .modifier(ExpandCollapseActions(isExpandable: isExpandable, isExpanded: isExpanded) { toggle() })
        .accessibilityAction(named: L("accessibility.zoomIn")) {
            if row.kind == .node, tree.node(row.node).isDirectory { state.navigate(to: row.node) }
        }
    }

    private var isExpanded: Bool { row.kind == .node && state.expanded.contains(row.node) }

    private var isExpandable: Bool { row.kind == .node && tree.node(row.node).childCount > 0 }

    @ViewBuilder private var disclosure: some View {
        if isExpandable {
            let open = state.expanded.contains(row.node)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
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
        case .unassigned:
            Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary).frame(width: 16)
        }
    }

    private var title: String {
        switch row.kind {
        case .node: tree.name(of: row.node)
        case .more(_, let count): itemsText(count)
        case .unassigned: L("arc.unassigned.title")
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

/// VoiceOver-Aktionen „Aufklappen“ bzw. „Zuklappen“ für Ordnerzeilen (der
/// Pfeil selbst ist für VoiceOver ausgeblendet).
struct ExpandCollapseActions: ViewModifier {
    let isExpandable: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        if isExpandable {
            content.accessibilityAction(named: isExpanded ? L("accessibility.collapse") : L("accessibility.expand")) { toggle() }
        } else {
            content
        }
    }
}
