import AppKit
import DiskRingsCore
import SwiftUI

/// Bestätigungsdialog für den Papierkorb (SPEC 3.6): Name, Größe und
/// Dateianzahl bzw. Summe; „Nicht mehr fragen“ nur unter 1 GB.
struct TrashConfirmationView: View {
    let plan: TrashPlan
    var onCancel: () -> Void
    var onConfirm: (_ dontAskAgain: Bool) -> Void
    @ViewState private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    let lines = plan.message.split(separator: "\n", maxSplits: 1).map(String.init)
                    Text(lines[0]).font(.system(size: 13).monospacedDigit())
                    if lines.count > 1 {
                        Text(lines[1])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text(L("trash.confirm.undoHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if plan.allowsDontAskAgain {
                Toggle(L("trash.confirm.dontAsk"), isOn: $dontAskAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            } else {
                Label(L("trash.confirm.alwaysAsk"), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("common.cancel"), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("action.moveToTrash")) { onConfirm(dontAskAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Informationen zu einem Element (⌘I): eigenes Fenster statt Finder-Info
/// per AppleScript (das bräuchte die Automations-Freigabe).
struct NodeInfoView: View {
    let state: AppState
    let node: Int32
    var onClose: () -> Void

    var body: some View {
        if let tree = state.tree, Int(node) < tree.count {
            let n = tree[node]
            let attrs = (try? FileManager.default.attributesOfItem(atPath: n.path)) ?? [:]
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: n.path))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.headline).lineLimit(2)
                        Text(kind(n)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row(L("info.where"), n.path, selectable: true)
                    row(L("info.allocated"), L("info.sizeWithBytes", ByteFormat.string(n.allocatedSize), Int(clamping: n.allocatedSize), ByteFormat.count(n.allocatedSize)))
                    row(L("info.logical"), L("info.sizeWithBytes", ByteFormat.string(n.logicalSize), Int(clamping: n.logicalSize), ByteFormat.count(n.logicalSize)))
                    if n.isDirectory {
                        row(L("info.contents"), L("info.contents.value", filesText(n.fileCount), L("count.entries", n.itemCount, ByteFormat.count(n.itemCount))))
                    }
                    if let d = attrs[.modificationDate] as? Date { row(L("info.modified"), Self.dateFormat.string(from: d)) }
                    if let d = attrs[.creationDate] as? Date { row(L("info.created"), Self.dateFormat.string(from: d)) }
                    if !n.badges.isEmpty { row(L("info.badges"), n.badges.joined(separator: L("list.separator"))) }
                    if let r = state.protection.reason(for: n.path) { row(L("info.protected"), r.message) }
                }
                .font(.system(size: 12))
                HStack {
                    Button(L("action.revealInFinder")) { FileActions.reveal([URL(fileURLWithPath: n.path)]) }
                    Spacer()
                    Button(L("common.done")) { onClose() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func kind(_ n: NodeRef) -> String {
        if n.isPackage { return L("kind.package") }
        if n.isSymlink { return L("kind.symlink") }
        if n.isDirectory { return L("kind.folder") }
        return L("kind.file")
    }

    @ViewBuilder private func row(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            if selectable {
                Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            } else {
                Text(value).monospacedDigit()
            }
        }
    }
}

/// Kurzer Hinweis unten im Diagramm.
struct ToastView: View {
    let state: AppState
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
            Text(toast.message)
                .font(.system(size: 12).monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if toast.offersUndo, state.canUndoTrash {
                Button(L("menu.undo")) { state.undoTrash() }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }
            Button { state.toast = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("toast.close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var icon: String {
        switch toast.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch toast.kind {
        case .info: .accentColor
        case .success: .green
        case .error: .orange
        }
    }
}

/// Suchfeld in der Toolbar (Suchknopf der Skizze 3.3).
struct SearchField: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("search.placeholder"), text: $state.searchQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if let first = state.searchResult?.matches.first { state.jump(to: first) } }
                .onExitCommand { state.clearSearch() }
            if state.isSearching { ProgressView().controlSize(.mini) }
            if !state.searchQuery.isEmpty {
                Button { state.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("search.clear"))
            }
        }
        .padding(.horizontal, 7)
        .frame(width: 220, height: 24)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { focused = true }
    }
}

/// Trefferliste der Suche (ersetzt rechts die Detailliste, solange gesucht wird).
struct SearchResultsView: View {
    let state: AppState

    var body: some View {
        if let tree = state.tree {
            VStack(spacing: 0) {
                HStack {
                    Text(header).font(.headline)
                    Spacer()
                    Button(L("search.backToList")) { state.showSearchResults = false }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.searchResult?.matches ?? [], id: \.self) { node in
                            SearchResultRow(state: state, tree: tree, node: node)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("search.results"))
        }
    }

    private var header: String {
        guard let r = state.searchResult else { return L("search.searching") }
        if r.total == 0 { return L("search.noResults") }
        let shown = r.matches.count
        return shown < r.total ? L("search.results.limited", r.total, ByteFormat.count(r.total), ByteFormat.count(shown))
            : L("search.results.count", r.total, ByteFormat.count(r.total))
    }
}

private struct SearchResultRow: View {
    let state: AppState
    let tree: ScanTree
    let node: Int32
    @ViewState private var hovered = false

    var body: some View {
        let n = tree[node]
        let parentPath = n.parent.map { relative($0.path) } ?? ""
        HStack(spacing: 8) {
            Image(systemName: n.symbolName).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(n.name).lineLimit(1).truncationMode(.middle)
                Text(parentPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(n.size(state.prefs.sizeMode))).font(.system(size: 12).monospacedDigit())
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.primary.opacity(0.07) : .clear).padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { state.jump(to: node) }
        .contextMenu { NodeContextMenu(state: state, node: node) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { state.jump(to: node) }
    }

    private func relative(_ p: String) -> String {
        let root = tree.rootPath
        if p == root { return (root as NSString).lastPathComponent }
        if p.hasPrefix(root + "/") { return (root as NSString).lastPathComponent + "/" + p.dropFirst(root.count + 1) }
        return p
    }
}
