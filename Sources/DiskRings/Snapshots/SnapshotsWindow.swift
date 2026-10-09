import AppKit
import DiskRingsCore
import SwiftUI

/// Fenster „Snapshots“ (SPEC 3.9): Liste mit Datum, Name, Scan-Wurzel und
/// Gesamtgröße; umbenennen, löschen (mit Bestätigung), im Finder zeigen und
/// zwei Snapshots miteinander vergleichen.
struct SnapshotsWindow: View {
    static let id = "snapshots"

    let state: AppState
    var initialSelection: Set<SnapshotInfo.ID> = []
    @ViewState private var selection: Set<SnapshotInfo.ID> = []
    @ViewState private var renaming: SnapshotInfo?
    @ViewState private var newName = ""
    @ViewState private var confirmDelete = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let library = state.snapshots
        let selected = library.infos.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            if library.infos.isEmpty && library.damaged.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(L("snapshots.empty")).font(.headline)
                    Text(L("snapshots.empty.message"))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(library.infos, selection: $selection) {
                    TableColumn(L("snapshots.column.date")) { info in
                        Text(SnapshotNaming.longDate(info.metadata.date)).monospacedDigit()
                    }
                    .width(min: 120, ideal: 130)
                    TableColumn(L("snapshots.column.name")) { info in
                        Text(SnapshotNaming.normalized(info.metadata.name) ?? "–")
                            .foregroundStyle(info.metadata.name == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn(L("snapshots.column.root")) { info in
                        Text(rootLabel(info.metadata)).lineLimit(1).truncationMode(.middle).help(info.metadata.rootPath)
                    }
                    .width(min: 120, ideal: 230)
                    TableColumn(L("snapshots.column.size")) { info in
                        Text(ByteFormat.string(info.metadata.allocatedSize)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn(L("snapshots.column.file")) { info in
                        Text(ByteFormat.string(info.fileSize)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 70)
                }
                .contextMenu(forSelectionType: SnapshotInfo.ID.self) { ids in
                    let infos = library.infos.filter { ids.contains($0.id) }
                    if infos.count == 1 { Button(L("common.renameEllipsis")) { beginRename(infos[0]) } }
                    if infos.count == 2 { Button(L("snapshots.compareEachOther")) { compare(infos) } }
                    Button(L("action.revealInFinder")) { library.revealInFinder(infos) }
                    Divider()
                    Button(L("common.deleteEllipsis")) {
                        selection = ids
                        confirmDelete = true
                    }
                }
            }
            if !library.damaged.isEmpty {
                Divider()
                DamagedSnapshotsList(library: library)
            }
            Divider()
            HStack(spacing: 8) {
                Button(L("common.renameEllipsis")) { if let s = selected.first { beginRename(s) } }
                    .disabled(selected.count != 1)
                Button(L("common.deleteEllipsis")) { confirmDelete = true }
                    .disabled(selected.isEmpty)
                Button(L("action.revealInFinder")) { library.revealInFinder(selected) }
                    .disabled(selected.isEmpty)
                Spacer()
                if let e = library.errorMessage {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(selected.count == 2 ? L("snapshots.olderIsBefore") : L("snapshots.selectTwo"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(L("compare.button")) { compare(selected) }
                    .disabled(selected.count != 2)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 300)
        .onAppear {
            library.refresh()
            if selection.isEmpty { selection = initialSelection }
        }
        .sheet(item: $renaming) { info in
            SnapshotNameSheet(title: L("snapshots.rename.title"), message: L("snapshots.rename.message", info.metadata.rootPath, SnapshotNaming.longDate(info.metadata.date)),
                              confirm: L("common.rename"), name: $newName) { ok in
                if ok { library.rename(info, to: newName) }
                renaming = nil
            }
        }
        .confirmationDialog(deleteTitle(selected.count), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("common.delete"), role: .destructive) {
                library.delete(selected)
                selection = []
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("snapshots.delete.message"))
        }
    }

    private func rootLabel(_ m: SnapshotMetadata) -> String {
        if let v = m.volume, v.unassigned != nil { return "\(v.name) (\(m.rootPath))" }
        return m.rootPath
    }

    private func deleteTitle(_ n: Int) -> String {
        n == 1 ? L("snapshots.delete.title.one") : L("snapshots.delete.title.count", n, ByteFormat.count(n))
    }

    private func beginRename(_ info: SnapshotInfo) {
        newName = info.metadata.name ?? ""
        renaming = info
    }

    private func compare(_ infos: [SnapshotInfo]) {
        guard infos.count == 2 else { return }
        state.compareSnapshots(infos[0], infos[1])
        openWindow(id: WindowLifecycle.mainWindowID)
    }
}

/// Beschädigte Snapshot-Dateien (abgeschnitten oder unlesbar): nur
/// anzeigen, im Finder zeigen und löschen.
struct DamagedSnapshotsList: View {
    let library: SnapshotLibrary
    @ViewState private var confirm: [DamagedSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("snapshots.damaged.count", library.damaged.count, ByteFormat.count(library.damaged.count)),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if library.damaged.count > 1 {
                    Button(L("snapshots.damaged.deleteAll")) { confirm = library.damaged }.controlSize(.small)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(library.damaged) { d in
                        HStack(spacing: 8) {
                            Text(d.statusLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((d.kind == .newerVersion ? Color.blue : Color.orange).opacity(0.2),
                                            in: Capsule())
                            Text(title(d)).lineLimit(1).truncationMode(.middle)
                            Text(d.reason).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text(ByteFormat.string(d.fileSize)).monospacedDigit().foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([d.url]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help(L("action.revealInFinder"))
                            Button { confirm = [d] } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help(L("common.deleteEllipsis"))
                        }
                        .font(.system(size: 11))
                        .help(d.url.path)
                    }
                }
            }
            .frame(height: min(90, CGFloat(library.damaged.count) * 22))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
        .confirmationDialog(confirm.count == 1 ? L("snapshots.damaged.delete.title.one") : L("snapshots.damaged.delete.title.count", confirm.count, ByteFormat.count(confirm.count)),
                            isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }),
                            titleVisibility: .visible) {
            Button(L("common.delete"), role: .destructive) {
                library.deleteDamaged(confirm)
                confirm = []
            }
            Button(L("common.cancel"), role: .cancel) { confirm = [] }
        } message: {
            Text(confirm.contains { $0.kind == .newerVersion }
                ? L("snapshots.damaged.delete.newer")
                : L("snapshots.damaged.delete.message"))
        }
    }

    private func title(_ d: DamagedSnapshot) -> String {
        guard let m = d.metadata else { return d.url.lastPathComponent }
        return "\(SnapshotNaming.title(m)) · \(m.rootPath)"
    }
}

/// Dialog mit einem optionalen Namen (Snapshot sichern bzw. umbenennen).
struct SnapshotNameSheet: View {
    let title: String
    let message: String
    let confirm: String
    @Binding var name: String
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            TextField(L("snapshots.name.placeholder"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { done(true) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { done(false) }.keyboardShortcut(.cancelAction)
                Button(confirm) { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}

/// Menü „Ablage“: Snapshot sichern (⌘S) und Fenster „Snapshots“.
struct SnapshotCommands: Commands {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(L("menu.saveSnapshot")) { state.snapshots.showSavePrompt = true }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.tree == nil || state.summary == nil || state.phase != .browsing)
            Button(L("menu.snapshots")) { openWindow(id: SnapshotsWindow.id) }
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}

/// Dialog „Snapshot sichern“, Fortschritt des Vergleichs, Fehler und kurze
/// Rückmeldungen im Hauptfenster (einziger Haken in `RootView`).
struct SnapshotUIHost: ViewModifier {
    let state: AppState
    @ViewState private var name = ""

    func body(content: Content) -> some View {
        let library = state.snapshots
        content
            .sheet(isPresented: Binding(get: { library.showSavePrompt }, set: { library.showSavePrompt = $0 })) {
                SnapshotNameSheet(title: L("snapshots.save.title"), message: saveMessage, confirm: L("snapshots.save.confirm"), name: $name) { ok in
                    if ok { library.saveCurrent(state: state, name: name) }
                    name = ""
                    library.showSavePrompt = false
                }
            }
            .overlay(alignment: .bottom) {
                if let text = library.busy ?? library.notice {
                    HStack(spacing: 8) {
                        if library.busy != nil { ProgressView().controlSize(.small) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(text)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
                }
            }
            .alert(L("snapshots.window.title"), isPresented: Binding(get: { library.errorMessage != nil && state.phase != .scanning },
                                                     set: { if !$0 { library.errorMessage = nil } })) {
                Button(L("common.ok"), role: .cancel) { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
    }

    private var saveMessage: String {
        guard let tree = state.tree else { return "" }
        return L("snapshots.save.message", tree.rootPath)
    }
}

/// Snapshot-Einstellungen (SPEC 3.7) in den Einstellungen.
struct SnapshotSettingsSection: View {
    @Bindable var prefs: SnapshotPreferences

    var body: some View {
        Section {
            Toggle(L("settings.snapshots.autoSave"), isOn: $prefs.autoSave)
            Stepper(value: $prefs.maxCount, in: SnapshotRetention.maxCountRange) {
                LabeledContent(L("settings.snapshots.maxCount"), value: ByteFormat.count(prefs.maxCount))
            }
        } header: {
            Text(L("settings.section.snapshots"))
        } footer: {
            Text(L("settings.snapshots.footer"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
