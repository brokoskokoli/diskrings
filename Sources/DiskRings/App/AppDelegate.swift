import AppKit
import DiskRingsCore
import SwiftUI

/// App-Lebenszyklus wie beim Festplattendienstprogramm: Mit dem letzten
/// sichtbaren Fenster endet die App; ein Klick aufs Dock-Symbol ohne
/// sichtbares Fenster holt ein minimiertes Fenster zurück oder öffnet das
/// Hauptfenster (Entscheidung in `WindowLifecycle`, Core).
///
/// Vorher (nur `Window`-Szenen, kein Delegate) blieb die App nach dem
/// Schließen des Hauptfensters im Dock, und der Klick aufs Symbol tat nichts:
/// SwiftUI öffnet beim Reopen nur `WindowGroup`-Szenen neu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState(prefs: Preferences())
    /// Von `RootView` beim ersten Erscheinen gesetzt; bleibt gültig, auch wenn
    /// das Fenster später geschlossen wird.
    var openWindow: OpenWindowAction?
    /// Nur für den Selbsttest (Einstellungsfenster öffnen).
    var openSettings: OpenSettingsAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `onDisappear` der Fensteransicht kommt beim Schließen nicht zuverlässig.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard WindowLifecycle.isMainWindow(identifier: window?.identifier?.rawValue) else { return }
                self?.mainWindowDidClose()
            }
        }
        if let steps = WindowLifecycle.selftestSteps(CommandLine.arguments) {
            runCloseSelftest(steps)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let windows = sender.windows
        let infos = windows.map {
            WindowLifecycle.WindowInfo(identifier: $0.identifier?.rawValue, isVisible: $0.isVisible,
                                       isMiniaturized: $0.isMiniaturized, canBecomeMain: $0.canBecomeMain)
        }
        let action = WindowLifecycle.reopenAction(hasVisibleWindows: flag, windows: infos)
        selftestLog("Dock-Klick (sichtbare Fenster: \(flag)) → \(action)")
        switch action {
        case .none:
            return true
        case .deminiaturize(let i):
            windows[i].deminiaturize(nil)
            return false
        case .openMain:
            openWindow?(id: WindowLifecycle.mainWindowID)
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Laufende Scans sauber beenden (Worker prüfen die Abbruch-Markierung).
        state.cancelScan()
        state.cancelPartialRescans()
        selftestLog("App wird beendet")
    }

    /// Das Hauptfenster wurde geschlossen: Ein laufender Scan wird abgebrochen,
    /// auch wenn die App wegen eines anderen offenen Fensters weiterläuft.
    func mainWindowDidClose() {
        let wasScanning = state.phase == .scanning
        state.cancelScan()
        state.cancelPartialRescans()
        selftestLog("Hauptfenster geschlossen\(wasScanning ? ", laufender Scan abgebrochen" : "")")
    }

    // MARK: Selbsttest (`--selftest-close [ids]`)

    private var selftest = false

    private func selftestLog(_ message: String) {
        guard selftest else { return }
        FileHandle.standardError.write(Data("selftest: \(message)\n".utf8))
    }

    /// Ablauf siehe `WindowLifecycle.selftestSteps`. Endet der Prozess nach
    /// dem letzten geschlossenen Fenster, ist das Verhalten richtig; läuft er
    /// noch (minimiert, ausgeblendet), beendet er sich nach 6 s selbst.
    private func runCloseSelftest(_ steps: [WindowLifecycle.SelftestStep]) {
        selftest = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for id in Set(steps.compactMap(\.windowID)) where !WindowLifecycle.isMainWindow(identifier: id) {
                if id == "settings" { openSettings?() } else { openWindow?(id: id) }
            }
            try? await Task.sleep(for: .seconds(1))
            selftestLog("Fenster: \(describeWindows())")
            for step in steps {
                switch step {
                case .dockClick:
                    let visible = NSApp.windows.contains { $0.isVisible }
                    if applicationShouldHandleReopen(NSApp, hasVisibleWindows: visible) {
                        selftestLog("Reopen an AppKit weitergereicht")
                    }
                case .hideApp:
                    selftestLog("blende App aus (⌘H)")
                    NSApp.hide(nil)
                case .close(let id), .minimize(let id), .orderOut(let id):
                    guard let window = selftestWindow(id) else {
                        selftestLog("Fenster \(id) nicht gefunden")
                        continue
                    }
                    if case .minimize = step {
                        selftestLog("minimiere \(id)")
                        window.miniaturize(nil)
                    } else if case .orderOut = step {
                        selftestLog("blende \(id) aus")
                        window.orderOut(nil)
                    } else {
                        selftestLog("schließe \(id) (Scan läuft: \(state.phase == .scanning))")
                        window.performClose(nil)
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
                selftestLog("läuft noch; sichtbar: \(describeWindows())")
            }
            try? await Task.sleep(for: .seconds(6))
            selftestLog("Selbsttest-Ende, sichtbar: \(describeWindows())")
            NSApp.terminate(nil)
        }
    }

    private func selftestWindow(_ id: String) -> NSWindow? {
        NSApp.windows.first { w in
            let wid = w.identifier?.rawValue
            guard w.isVisible else { return false }
            if id == WindowLifecycle.mainWindowID { return WindowLifecycle.isMainWindow(identifier: wid) }
            if id == "settings" { return wid?.contains("Settings") == true }
            return wid == id
        }
    }

    private func describeWindows() -> String {
        let visible = NSApp.windows.filter(\.isVisible).map { $0.identifier?.rawValue ?? "?" }
        return visible.isEmpty ? "keine" : visible.joined(separator: ", ")
    }
}
