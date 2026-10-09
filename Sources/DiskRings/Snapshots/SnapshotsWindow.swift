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
                    Text("Noch keine Snapshots").font(.headline)
                    Text("Snapshots entstehen automatisch nach jedem vollständigen Scan (abschaltbar in den Einstellungen) oder mit „Ablage → Snapshot sichern“ (⌘S).")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(library.infos, selection: $selection) {
                    TableColumn("Datum") { info in
                        Text(SnapshotNaming.longDate(info.metadata.date)).monospacedDigit()
                    }
                    .width(min: 120, ideal: 130)
                    TableColumn("Name") { info in
                        Text(SnapshotNaming.normalized(info.metadata.name) ?? "–")
                            .foregroundStyle(info.metadata.name == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Scan-Wurzel") { info in
                        Text(rootLabel(info.metadata)).lineLimit(1).truncationMode(.middle).help(info.metadata.rootPath)
                    }
                    .width(min: 120, ideal: 230)
                    TableColumn("Gesamtgröße") { info in
                        Text(ByteFormat.string(info.metadata.allocatedSize)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Datei") { info in
                        Text(ByteFormat.string(info.fileSize)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 60, ideal: 70)
                }
                .contextMenu(forSelectionType: SnapshotInfo.ID.self) { ids in
                    let infos = library.infos.filter { ids.contains($0.id) }
                    if infos.count == 1 { Button("Umbenennen…") { beginRename(infos[0]) } }
                    if infos.count == 2 { Button("Miteinander vergleichen") { compare(infos) } }
                    Button("Im Finder zeigen") { library.revealInFinder(infos) }
                    Divider()
                    Button("Löschen…") {
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
                Button("Umbenennen…") { if let s = selected.first { beginRename(s) } }
                    .disabled(selected.count != 1)
                Button("Löschen…") { confirmDelete = true }
                    .disabled(selected.isEmpty)
                Button("Im Finder zeigen") { library.revealInFinder(selected) }
                    .disabled(selected.isEmpty)
                Spacer()
                if let e = library.errorMessage {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(selected.count == 2 ? "Der ältere ist „vorher“" : "Zum Vergleichen zwei Snapshots auswählen")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Vergleichen") { compare(selected) }
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
            SnapshotNameSheet(title: "Snapshot umbenennen", message: "Scan von \(info.metadata.rootPath), \(SnapshotNaming.longDate(info.metadata.date))",
                              confirm: "Umbenennen", name: $newName) { ok in
                if ok { library.rename(info, to: newName) }
                renaming = nil
            }
        }
        .confirmationDialog(deleteTitle(selected.count), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.delete(selected)
                selection = []
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Snapshot-Datei wird endgültig gelöscht. Gescannte Dateien und Ordner bleiben unberührt.")
        }
    }

    private func rootLabel(_ m: SnapshotMetadata) -> String {
        if let v = m.volume, v.unassigned != nil { return "\(v.name) (\(m.rootPath))" }
        return m.rootPath
    }

    private func deleteTitle(_ n: Int) -> String {
        n == 1 ? "Snapshot löschen?" : "\(n) Snapshots löschen?"
    }

    private func beginRename(_ info: SnapshotInfo) {
        newName = info.metadata.name ?? ""
        renaming = info
    }

    private func compare(_ infos: [SnapshotInfo]) {
        guard infos.count == 2 else { return }
        state.compareSnapshots(infos[0], infos[1])
        openWindow(id: "main")
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
                Label("\(library.damaged.count == 1 ? "1 nicht lesbare Datei" : "\(library.damaged.count) nicht lesbare Dateien")",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if library.damaged.count > 1 {
                    Button("Alle löschen…") { confirm = library.damaged }.controlSize(.small)
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
                            .help("Im Finder zeigen")
                            Button { confirm = [d] } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Löschen…")
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
        .confirmationDialog(confirm.count == 1 ? "Nicht lesbare Datei löschen?" : "\(confirm.count) nicht lesbare Dateien löschen?",
                            isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = [] } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                library.deleteDamaged(confirm)
                confirm = []
            }
            Button("Abbrechen", role: .cancel) { confirm = [] }
        } message: {
            Text(confirm.contains { $0.kind == .newerVersion }
                ? "Darunter sind Snapshots einer neueren DiskRings-Version, die diese Version nicht lesen kann; eine neuere App könnte sie noch öffnen. Die Dateien werden endgültig gelöscht. Gescannte Dateien und Ordner bleiben unberührt."
                : "Die Datei lässt sich nicht mehr als Snapshot lesen und wird endgültig gelöscht. Gescannte Dateien und Ordner bleiben unberührt.")
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
            TextField("Name (optional), z. B. „vor Xcode-Update“", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { done(true) }
            HStack {
                Spacer()
                Button("Abbrechen") { done(false) }.keyboardShortcut(.cancelAction)
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
            Button("Snapshot sichern…") { state.snapshots.showSavePrompt = true }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.tree == nil || state.summary == nil || state.phase != .browsing)
            Button("Snapshots…") { openWindow(id: SnapshotsWindow.id) }
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
                SnapshotNameSheet(title: "Snapshot sichern", message: saveMessage, confirm: "Sichern", name: $name) { ok in
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
            .alert("Snapshots", isPresented: Binding(get: { library.errorMessage != nil && state.phase != .scanning },
                                                     set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK", role: .cancel) { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
    }

    private var saveMessage: String {
        guard let tree = state.tree else { return "" }
        return "Aktueller Scan von \(tree.rootPath)"
    }
}

/// Snapshot-Einstellungen (SPEC 3.7) in den Einstellungen.
struct SnapshotSettingsSection: View {
    @Bindable var prefs: SnapshotPreferences

    var body: some View {
        Section {
            Toggle("Nach jedem vollständigen Scan automatisch speichern", isOn: $prefs.autoSave)
            Stepper(value: $prefs.maxCount, in: SnapshotRetention.maxCountRange) {
                LabeledContent("Höchstens pro Scan-Wurzel", value: "\(prefs.maxCount)")
            }
        } header: {
            Text("Snapshots")
        } footer: {
            Text("Gespeichert werden Ordner und Dateien ab 1 MB. Sind es mehr als die Höchstzahl, werden die ältesten gelöscht.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
