import AppKit
import DiskRingsCore
import SwiftUI

/// Detailliste im Vergleichsmodus (SPEC 3.9): Outline der Kinder des Fokus
/// (auch entfernte) mit den Spalten Vorher, Jetzt und Δ, sortierbar per
/// Klick auf die Spaltenüberschrift (Standard: Δ absteigend).
struct CompareListView: View {
    let state: AppState
    let session: CompareSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    static let rowsPerLevel = 400
    static let sizeColumn: CGFloat = 70
    static let deltaColumn: CGFloat = 78

    var body: some View {
        let model = session.model
        VStack(spacing: 0) {
            header(model)
            Divider()
            columnHeader
            Divider()
            ScrollViewReader { proxy in
                let rows = rows(model)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            CompareRowView(state: state, session: session, row: row, listFocused: focused,
                                           focusList: { focused = true })
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, rows: rows, proxy: proxy) }
                .onChange(of: session.scrollRequest) { _, target in
                    guard let target else { return }
                    if reduceMotion {
                        proxy.scrollTo(CompareRow.ID.entry(target), anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(CompareRow.ID.entry(target), anchor: .center) }
                    }
                    session.scrollRequest = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("compare.list.accessibility", model.diff.name(of: session.focus)))
    }

    /// Tastatur wie in der Detailliste (`OutlineNavigation`); ⏎ zoomt in den Ordner.
    private func handleKey(_ press: KeyPress, rows: [CompareRow], proxy: ScrollViewProxy) -> KeyPress.Result {
        let diff = session.model.diff
        if OutlineKeyboard.isReturn(press) {
            guard let e = session.selected, diff.isDirectory(e) else { return .ignored }
            session.navigate(to: e)
            return .handled
        }
        guard let key = OutlineKeyboard.key(press) else { return .ignored }
        let outline = rows.map { r in
            OutlineRow(id: r.id, level: r.level, isSelectable: r.kind == .entry,
                       isExpandable: r.kind == .entry && CompareRowView.isExpandable(r.entry, diff: diff),
                       isExpanded: r.kind == .entry && session.expanded.contains(r.entry))
        }
        let current = session.selected.map { CompareRow.ID.entry($0) }
        switch OutlineNavigation.command(for: key, current: current, rows: outline) {
        case .select(let id):
            if case .entry(let e) = id {
                session.selected = e
                proxy.scrollTo(id)
            }
        case .expand(let id):
            if case .entry(let e) = id { session.expanded.insert(e) }
        case .collapse(let id):
            if case .entry(let e) = id { session.expanded.remove(e) }
        case .none:
            break
        }
        return .handled
    }

    private func header(_ m: CompareModel) -> some View {
        let e = session.focus
        let d = m.diff.delta(e, m.mode)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(m.diff.name(of: e)).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Text(CompareText.beforeNow(m, e)).monospacedDigit()
                Text(TextFormat.inlineSeparatorGlyph)
                Text("Δ " + ByteFormat.signed(d)).fontWeight(.semibold).monospacedDigit().foregroundStyle(deltaTextColor(d))
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            sortButton(L("compare.column.name"), .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
            sortButton(L("compare.column.before"), .before).frame(width: Self.sizeColumn, alignment: .trailing)
            sortButton(L("compare.column.now"), .now).frame(width: Self.sizeColumn, alignment: .trailing)
            sortButton("Δ", .delta).frame(width: Self.deltaColumn, alignment: .trailing)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(minHeight: 24)
    }

    private func sortButton(_ title: String, _ key: CompareSort.Key) -> some View {
        Button { session.sort.toggle(key) } label: {
            HStack(spacing: 2) {
                Text(title)
                if session.sort.key == key {
                    Image(systemName: session.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                }
            }
            .fontWeight(session.sort.key == key ? .semibold : .medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("compare.sortBy", title))
        .accessibilityLabel(L("compare.sortBy", title))
    }

    private func rows(_ m: CompareModel) -> [CompareRow] {
        var out: [CompareRow] = []
        func add(_ parent: Int32, level: Int) {
            let kids = m.children(of: parent, sortedBy: session.sort)
            for (n, k) in kids.enumerated() {
                if n == Self.rowsPerLevel {
                    out.append(CompareRow(kind: .more(parent: parent, count: kids.count - n), entry: k, level: level))
                    break
                }
                out.append(CompareRow(kind: .entry, entry: k, level: level))
                if session.expanded.contains(k) { add(k, level: level + 1) }
            }
        }
        add(session.focus, level: 0)
        return out
    }
}

struct CompareRow: Identifiable {
    enum Kind: Equatable { case entry, more(parent: Int32, count: Int) }
    enum ID: Hashable { case entry(Int32), more(Int32) }
    let kind: Kind
    let entry: Int32
    let level: Int

    var id: ID {
        switch kind {
        case .entry: .entry(entry)
        case .more(let p, _): .more(p)
        }
    }
}

private struct CompareRowView: View {
    let state: AppState
    let session: CompareSession
    let row: CompareRow
    /// Die Liste hat den Tastaturfokus.
    let listFocused: Bool
    let focusList: () -> Void

    @ScaledMetric(relativeTo: .callout) private var indent: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = 24

    var body: some View {
        let m = session.model
        let e = row.entry
        let isEntry = row.kind == .entry
        let status = m.diff.status(e, m.mode)
        let isSelected = isEntry && session.selected == e
        let isHovered = isEntry && session.hoverEntry == e
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.level) * indent, height: 1)
            disclosure
            if isEntry {
                Image(systemName: statusSymbol(status)).foregroundStyle(statusColor(status)).frame(width: 16)
                    .help(status.label)
                Text(m.diff.name(of: e))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(status == .removed, color: .secondary)
                    .foregroundStyle(status == .removed ? .secondary : .primary)
                Spacer(minLength: 6)
                Text(status == .added ? "–" : ByteFormat.string(m.diff.oldSize(e, m.mode)))
                    .foregroundStyle(.secondary)
                    .frame(width: CompareListView.sizeColumn, alignment: .trailing)
                Text(status == .removed ? "–" : ByteFormat.string(m.diff.newSize(e, m.mode)))
                    .frame(width: CompareListView.sizeColumn, alignment: .trailing)
                let d = m.diff.delta(e, m.mode)
                Text(d == 0 ? "0" : ByteFormat.signed(d))
                    .fontWeight(.medium)
                    .foregroundStyle(deltaTextColor(d))
                    .frame(width: CompareListView.deltaColumn, alignment: .trailing)
            } else if case .more(_, let count) = row.kind {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 16)
                Text(L("count.moreItems", count, ByteFormat.count(count))).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(OutlineKeyboard.rowBackground(selected: isSelected, hovered: isHovered, listFocused: listFocused))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if isEntry { session.hoverList(inside ? e : (session.hoverEntry == e ? nil : session.hoverEntry)) }
        }
        .onTapGesture {
            focusList()
            guard isEntry else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                session.navigate(to: e)
            } else {
                session.selected = e
                if isExpandable { toggle() }
            }
        }
        .contextMenu { if isEntry { CompareContextMenu(state: state, entry: e) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isEntry ? CompareText.accessibility(m, e) : L("compare.moreItems"))
        .accessibilityValue(isEntry
            ? OutlineAccessibility.value(level: row.level, isExpandable: isExpandable, isExpanded: isExpanded) : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction {
            guard isEntry else { return }
            session.selected = e
            if isExpandable { toggle() }
        }
        .modifier(ExpandCollapseActions(isExpandable: isExpandable, isExpanded: isExpanded) { toggle() })
        .accessibilityAction(named: L("accessibility.zoomIn")) {
            if isEntry, m.diff.isDirectory(e) { session.navigate(to: e) }
        }
    }

    static func isExpandable(_ e: Int32, diff: SnapshotDiff) -> Bool {
        diff.isDirectory(e) && !diff.childEntries(of: e).isEmpty
    }

    private var isExpandable: Bool { row.kind == .entry && Self.isExpandable(row.entry, diff: session.model.diff) }
    private var isExpanded: Bool { row.kind == .entry && session.expanded.contains(row.entry) }

    @ViewBuilder private var disclosure: some View {
        if isExpandable {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(session.expanded.contains(row.entry) ? 90 : 0))
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func toggle() {
        if session.expanded.contains(row.entry) { session.expanded.remove(row.entry) } else { session.expanded.insert(row.entry) }
    }
}

/// Tab „Größte Veränderungen“ (SPEC 3.9): Top 50 der Ordner und Dateien mit
/// dem größten Zuwachs (bzw. Rückgang), nur der tiefste aussagekräftige Ordner.
struct LargestChangesView: View {
    let state: AppState
    let session: CompareSession
    @FocusState private var focused: Bool

    var body: some View {
        let m = session.model
        let changes = m.largestChanges(growth: !session.showShrink)
        VStack(spacing: 0) {
            Picker(L("compare.direction"), selection: Binding(get: { session.showShrink }, set: { session.showShrink = $0 })) {
                Text(L("compare.direction.growth")).tag(false)
                Text(L("compare.direction.shrink")).tag(true)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if changes.isEmpty {
                Text(session.showShrink ? L("compare.largest.noShrink") : L("compare.largest.noGrowth"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(changes.enumerated()), id: \.element.entry) { i, c in
                                LargestChangeRow(state: state, session: session, rank: i + 1, change: c,
                                                 relativePath: relative(c.path, root: m.diff.new.metadata.rootPath),
                                                 listFocused: focused, focusList: { focused = true })
                                    .id(c.entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press, changes: changes, proxy: proxy) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("compare.tab.largest"))
    }

    /// ↑/↓, Pos1/Ende, Bild↑/↓ wählen aus; ⏎ zeigt den Eintrag im Diagramm und in „Inhalt“.
    private func handleKey(_ press: KeyPress, changes: [DiffChange], proxy: ScrollViewProxy) -> KeyPress.Result {
        if OutlineKeyboard.isReturn(press) {
            guard let e = session.selected, changes.contains(where: { $0.entry == e }) else { return .ignored }
            session.reveal(e)
            return .handled
        }
        guard let key = OutlineKeyboard.key(press) else { return .ignored }
        let rows = changes.map { OutlineRow(id: $0.entry, level: 0) }
        if let e = OutlineNavigation.command(for: key, current: session.selected, rows: rows).target {
            session.selected = e
            session.hoverList(e)
            proxy.scrollTo(e)
        }
        return .handled
    }

    private func relative(_ path: String, root: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == root { return L("compare.inScanRoot") }
        if parent.hasPrefix(root + "/") { return L("compare.inFolder", String(parent.dropFirst(root.count + 1))) }
        return parent
    }
}

private struct LargestChangeRow: View {
    let state: AppState
    let session: CompareSession
    let rank: Int
    let change: DiffChange
    let relativePath: String
    let listFocused: Bool
    let focusList: () -> Void

    @ScaledMetric(relativeTo: .callout) private var rowHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .callout) private var rankWidth: CGFloat = 22

    var body: some View {
        let isSelected = session.selected == change.entry
        let isHovered = session.hoverEntry == change.entry
        HStack(spacing: 8) {
            Text(ByteFormat.count(rank)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: rankWidth, alignment: .trailing)
            Image(systemName: change.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(change.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if change.status == .added || change.status == .removed {
                        Text(change.status.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(statusColor(change.status).opacity(0.18), in: Capsule())
                            .foregroundStyle(statusColor(change.status))
                    }
                }
                Text(relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                let signed = session.showShrink ? -Int64(clamping: change.amount) : Int64(clamping: change.amount)
                Text(ByteFormat.signed(signed)).font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(deltaTextColor(signed))
                Text((change.status == .added ? "–" : ByteFormat.string(change.oldSize)) + " → " + (change.status == .removed ? "–" : ByteFormat.string(change.newSize)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(OutlineKeyboard.rowBackground(selected: isSelected, hovered: isHovered, listFocused: listFocused))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in session.hoverList(inside ? change.entry : nil) }
        .onTapGesture {
            focusList()
            session.reveal(change.entry)
        }
        .contextMenu { CompareContextMenu(state: state, entry: change.entry) }
        .help(change.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("compare.largest.row.accessibility", ByteFormat.count(rank), change.name, change.status.label, ByteFormat.signed(change.delta)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { session.reveal(change.entry) }
    }
}
