import AppKit
import DiskRingsCore
import Quartz

/// AppKit-Seite der Kontextmenü-Aktionen (SPEC 3.5). Die Regeln, wann eine
/// Aktion erlaubt ist, stehen in `NodeAction.availability` (Core).
@MainActor
enum FileActions {
    /// Im Finder zeigen (⌘R).
    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Öffnen mit der Standard-App.
    static func open(_ urls: [URL]) {
        for u in urls { NSWorkspace.shared.open(u) }
    }

    /// Pfad kopieren (⌥⌘C); mehrere Pfade zeilenweise.
    static func copyPaths(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Steht der Cursor gerade in einem Textfeld (z. B. der Suche)?
    static var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSText) != nil
    }
}

/// Quick Look über `QLPreviewPanel` (SPEC 3.5, Leertaste; Doppelklick auf
/// eine Datei). Der Controller hängt sich als Responder hinter das Fenster in
/// die Responder-Kette, damit das Panel ihn als Datenquelle findet.
@MainActor
final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private(set) var urls: [URL] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(_ urls: [URL]) {
        if isVisible, urls == self.urls {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            show(urls)
        }
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, !(window is QLPreviewPanel) {
            attach(to: window)
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func attach(to window: NSWindow) {
        guard window.nextResponder !== self else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Die Panel-Steuerung kommt als NSObject-Kategorie ohne Actor-Angabe;
    // aufgerufen wird sie von AppKit auf dem Main Thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// Tastatur: Leertaste für Quick Look (ein Menü-Tastenkürzel ohne
/// Modifikator würde Leerzeichen im Suchfeld schlucken). Die übrigen
/// Kürzel hängen am Menü „Objekt“.
@MainActor
final class KeyboardMonitor {
    private var monitor: Any?
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated { self.handle(event) }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let state, state.phase == .browsing, state.trashRequest == nil, state.infoNode == nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 49, mods.isEmpty, !FileActions.isEditingText else { return false }
        // Im Quick-Look-Panel selbst schließt die Leertaste es wieder.
        if NSApp.keyWindow is QLPreviewPanel { return false }
        guard state.hasCommandTargets(for: .quickLook) else { return false }
        state.performCommand(.quickLook)
        return true
    }
}
