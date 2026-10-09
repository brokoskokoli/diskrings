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
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView(prefs: state.prefs)
        }
    }
}

struct RootView: View {
    let state: AppState
    @ViewState private var dropTargeted = false
    @ViewState private var swipe: SwipeNavigation?

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
            state.startScan(url.path)
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
            // `--scan <pfad>` startet sofort einen Scan (für Tests und Skripte).
            let args = CommandLine.arguments
            if state.phase == .start, let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
                state.startScan(args[i + 1])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Festplattenvollzugriff kann in den Systemeinstellungen erteilt worden sein.
            state.fullDiskAccess = FullDiskAccess.status()
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

/// Menübefehle: Navigation mit ⌘[ / ⌘] / ⌘↑, Rescan, Ordner wählen.
struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Ordner wählen…") { state.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Neu scannen") { state.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(state.tree == nil || state.phase == .scanning)
        }
        CommandMenu("Gehe zu") {
            Button("Zurück") { state.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.history.canGoBack)
            Button("Vor") { state.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.history.canGoForward)
            Button("Übergeordneter Ordner") { state.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(state.tree == nil || state.focus == ScanTree.rootIndex)
            Button("Zur Scan-Wurzel") { state.navigate(to: ScanTree.rootIndex) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(state.tree == nil || state.focus == ScanTree.rootIndex)
            Divider()
            Button("Startbildschirm") { state.backToStart() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
