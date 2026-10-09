import AppKit
import DiskRingsCore
import SwiftUI

/// Einstieg: Mit `--render-snapshots <ordner>` rendert die App Vorschaubilder
/// der Oberfläche als PNG und beendet sich (siehe `SnapshotRenderer`);
/// sonst startet sie normal.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-snapshots") {
            let dir = i + 1 < args.count ? args[i + 1] : "build/snapshots"
            let scanPath = args.firstIndex(of: "--scan").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            if args.contains("--compare-demo") {
                MainActor.assumeIsolated { exit(CompareDemoRenderer.run(outputDirectory: dir)) }
            }
            MainActor.assumeIsolated {
                exit(SnapshotRenderer.run(outputDirectory: dir, scanPath: scanPath))
            }
        }
        DiskRingsApp.main()
    }
}

struct DiskRingsApp: App {
    @ViewState private var state = AppState(prefs: Preferences())

    var body: some Scene {
        Window("DiskRings", id: "main") {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            AppCommands(state: state)
            SnapshotCommands(state: state)
        }

        Window("Snapshots", id: SnapshotsWindow.id) {
            SnapshotsWindow(state: state)
        }
        .defaultSize(width: 760, height: 420)

        Settings {
            SettingsView(prefs: state.prefs)
        }
    }
}

struct RootView: View {
    let state: AppState
    @ViewState private var dropTargeted = false
    @ViewState private var swipe: SwipeNavigation?
    @ViewState private var keyboard: KeyboardMonitor?

    var body: some View {
        Group {
            switch state.phase {
            case .start: StartView(state: state)
            case .scanning: ScanningView(state: state)
            case .browsing: BrowserView(state: state)
            }
        }
        .navigationTitle(title)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || isDirectory(url) else { return false }
            state.requestScan(url.path)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            state.refreshVolumes()
            if swipe == nil {
                let s = SwipeNavigation(state: state)
                s.install()
                swipe = s
            }
            if keyboard == nil {
                let k = KeyboardMonitor(state: state)
                k.install()
                keyboard = k
            }
            // `--scan <pfad>` startet sofort einen Scan (für Tests und Skripte).
            let args = CommandLine.arguments
            if state.phase == .start, let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
                state.startScan(args[i + 1])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Festplattenvollzugriff kann in den Systemeinstellungen erteilt worden sein.
            state.fullDiskAccess = FullDiskAccess.status()
            // Belegung kann sich außerhalb der App geändert haben.
            if state.phase == .browsing { state.refreshUnassigned() }
        }
        // Volume-Liste aktuell halten, wenn Volumes ein- oder ausgehängt werden.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            state.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            state.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            state.refreshVolumes()
        }
        .onChange(of: state.prefs.layoutKey) { _, _ in state.relayout(animated: false) }
        .modifier(SnapshotUIHost(state: state))
        .alert("Kein Festplattenvollzugriff",
               isPresented: Binding(get: { state.fullDiskAccessPromptPath != nil },
                                    set: { if !$0 { state.fullDiskAccessPromptPath = nil } })) {
            Button("Festplattenvollzugriff einrichten") { state.answerFullDiskAccessPrompt(scanAnyway: false) }
            Button("Trotzdem scannen") { state.answerFullDiskAccessPrompt(scanAnyway: true) }
            Button("Abbrechen", role: .cancel) { state.fullDiskAccessPromptPath = nil }
        } message: {
            Text("Ohne Festplattenvollzugriff fragt macOS beim Scan einzeln nach Ordnern wie Schreibtisch, Dokumente und Downloads, und Bereiche wie ~/Library/Mail bleiben unlesbar. Der Scan wartet, bis du die Systemdialoge beantwortest.\n\nEmpfohlen: In den Systemeinstellungen unter „Datenschutz & Sicherheit → Festplattenvollzugriff“ DiskRings einschalten und danach erneut scannen.")
        }
    }

    private var title: String {
        guard let tree = state.tree else { return "DiskRings" }
        if state.isVolumeRoot, let v = state.volume { return v.name }
        return (tree.rootPath as NSString).lastPathComponent
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// Menübefehle: Navigation mit ⌘[ / ⌘] / ⌘↑, Rescan, Ordner wählen, das
/// Menü „Objekt“ mit den Aktionen des Kontextmenüs und Undo für den Papierkorb.
struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Ordner wählen…") { state.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Komplett neu scannen") { state.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.tree == nil || state.phase == .scanning)
        }
        CommandGroup(replacing: .undoRedo) {
            // Im Suchfeld gehört ⌘Z dem Textfeld.
            Button(state.canUndoTrash ? state.undoTitle : "Widerrufen") {
                if FileActions.isEditingText {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    state.undoTrash()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("Wiederholen") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Suchen…") { if !state.searchVisible { state.toggleSearch() } }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(state.tree == nil)
        }
        CommandMenu("Objekt") {
            ForEach(NodeAction.allCases) { action in
                if action.startsGroup { Divider() }
                let button = Button(state.commandTitle(action)) { state.performCommand(action) }
                    .disabled(!state.commandAvailability(action).isEnabled)
                if action == .quickLook {
                    // Leertaste über `KeyboardMonitor`; im Menü ⌘Y wie im Finder.
                    button.keyboardShortcut("y", modifiers: .command)
                } else if let s = action.shortcut?.keyboardShortcut {
                    button.keyboardShortcut(s)
                } else {
                    button
                }
            }
        }
        // Im Vergleichsmodus wirkt „Gehe zu“ auf den Vergleich.
        CommandMenu("Gehe zu") {
            Button("Zurück") { state.navigateBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.canNavigateBack)
            Button("Vor") { state.navigateForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.canNavigateForward)
            Button("Übergeordneter Ordner") { state.navigateUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!state.canNavigateUp)
            Button(state.compare != nil ? "Zur Vergleichswurzel" : "Zur Scan-Wurzel") { state.navigateToRoot() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(!state.canNavigateUp)
            Divider()
            Button("Startbildschirm") { state.backToStart() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
