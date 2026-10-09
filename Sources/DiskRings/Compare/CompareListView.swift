import AppKit
import DiskRingsCore
import SwiftUI

/// Detailliste im Vergleichsmodus (SPEC 3.9): Outline der Kinder des Fokus
/// (auch entfernte) mit den Spalten Vorher, Jetzt und Δ, sortierbar per
/// Klick auf die Spaltenüberschrift (Standard: Δ absteigend).
struct CompareListView: View {
    let state: AppState
    let session: CompareSession

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows(model)) { row in
                            CompareRowView(session: session, row: row).id(row.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.scrollRequest) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(CompareRow.ID.entry(target), anchor: .center) }
                    session.scrollRequest = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vergleich: Inhalt von \(model.diff.name(of: session.focus))")
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
                Text("·")
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
            sortButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
            sortButton("Vorher", .before).frame(width: Self.sizeColumn, alignment: .trailing)
            sortButton("Jetzt", .now).frame(width: Self.sizeColumn, alignment: .trailing)
            sortButton("Δ", .delta).frame(width: Self.deltaColumn, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private func sortButton(_ title: String, _ key: CompareSort.Key) -> some View {
        Button { session.sort.toggle(key) } label: {
            HStack(spacing: 2) {
                Text(title)
                if session.sort.key == key {
                    Image(systemName: session.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .fontWeight(session.sort.key == key ? .semibold : .medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nach \(title) sortieren")
        .accessibilityLabel("Nach \(title) sortieren")
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
    let session: CompareSession
    let row: CompareRow

    var body: some View {
        let m = session.model
        let e = row.entry
        let isEntry = row.kind == .entry
        let status = m.diff.status(e, m.mode)
        let isSelected = isEntry && session.selected == e
        let isHovered = isEntry && session.hoverEntry == e
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.level) * 14, height: 1)
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
                Text("\(ByteFormat.count(count)) weitere Elemente").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.07) : .clear))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if isEntry { session.hoverList(inside ? e : (session.hoverEntry == e ? nil : session.hoverEntry)) }
        }
        .onTapGesture {
            guard isEntry else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                session.navigate(to: e)
            } else {
                session.selected = e
                if isExpandable { toggle() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isEntry ? CompareText.accessibility(m, e) : "weitere Elemente")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Hineinzoomen") { if isEntry { session.navigate(to: e) } }
    }

    private var isExpandable: Bool {
        row.kind == .entry && session.model.diff.isDirectory(row.entry) && !session.model.diff.childEntries(of: row.entry).isEmpty
    }

    @ViewBuilder private var disclosure: some View {
        if isExpandable {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
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
    let session: CompareSession

    var body: some View {
        let m = session.model
        let changes = m.largestChanges(growth: !session.showShrink)
        VStack(spacing: 0) {
            Picker("Richtung", selection: Binding(get: { session.showShrink }, set: { session.showShrink = $0 })) {
                Text("Zuwachs").tag(false)
                Text("Rückgang").tag(true)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if changes.isEmpty {
                Text(session.showShrink ? "Kein Rückgang ab 1 MB" : "Kein Zuwachs ab 1 MB")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(changes.enumerated()), id: \.element.entry) { i, c in
                            LargestChangeRow(session: session, rank: i + 1, change: c,
                                             relativePath: relative(c.path, root: m.diff.new.metadata.rootPath))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Größte Veränderungen")
    }

    private func relative(_ path: String, root: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == root { return "in der Scan-Wurzel" }
        if parent.hasPrefix(root + "/") { return "in " + String(parent.dropFirst(root.count + 1)) }
        return parent
    }
}

private struct LargestChangeRow: View {
    let session: CompareSession
    let rank: Int
    let change: DiffChange
    let relativePath: String

    var body: some View {
        let isSelected = session.selected == change.entry
        let isHovered = session.hoverEntry == change.entry
        HStack(spacing: 8) {
            Text("\(rank)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Image(systemName: change.isDirectory ? "folder.fill" : "doc").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(change.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if change.status == .added || change.status == .removed {
                        Text(change.status.label)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(statusColor(change.status).opacity(0.18), in: Capsule())
                            .foregroundStyle(statusColor(change.status))
                    }
                }
                Text(relativePath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                let signed = session.showShrink ? -Int64(clamping: change.amount) : Int64(clamping: change.amount)
                Text(ByteFormat.signed(signed)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(deltaTextColor(signed))
                Text("\(change.status == .added ? "–" : ByteFormat.string(change.oldSize)) → \(change.status == .removed ? "–" : ByteFormat.string(change.newSize))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : (isHovered ? Color.primary.opacity(0.07) : .clear))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in session.hoverList(inside ? change.entry : nil) }
        .onTapGesture { session.reveal(change.entry) }
        .help(change.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(change.name), \(change.status.label), \(ByteFormat.signed(change.delta))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { session.reveal(change.entry) }
    }
}
