@testable import DiskRingsCore
import Testing

/// Befund: Nach dem Schließen des Hauptfensters blieb die App im Dock, und ein
/// Klick aufs Dock-Symbol tat nichts. Jetzt beendet sich die App mit dem
/// letzten Fenster; ein Klick aufs Dock-Symbol ohne sichtbares Fenster holt
/// ein minimiertes Fenster zurück oder öffnet das Hauptfenster.
@Suite("Fenster-Lebenszyklus")
struct WindowLifecycleTests {
    private func w(_ id: String?, visible: Bool = true, minimized: Bool = false,
                   canBecomeMain: Bool = true) -> WindowLifecycle.WindowInfo {
        .init(identifier: id, isVisible: visible, isMiniaturized: minimized, canBecomeMain: canBecomeMain)
    }

    @Test("Sichtbares Fenster vorhanden: nichts tun")
    func visible() {
        let a = WindowLifecycle.reopenAction(hasVisibleWindows: true, windows: [w("main")])
        #expect(a == .none)
    }

    @Test("Kein Fenster: Hauptfenster öffnen")
    func noWindows() {
        #expect(WindowLifecycle.reopenAction(hasVisibleWindows: false, windows: []) == .openMain)
    }

    @Test("Nur unsichtbare Hilfsfenster (z. B. versteckte SwiftUI-Fenster): Hauptfenster öffnen")
    func hiddenOnly() {
        let a = WindowLifecycle.reopenAction(hasVisibleWindows: false,
                                             windows: [w(nil, visible: false, canBecomeMain: false),
                                                       w("com_apple_SwiftUI_Settings_window", visible: false)])
        #expect(a == .openMain)
    }

    @Test("Minimiertes Hauptfenster: zurückholen statt neu öffnen")
    func minimizedMain() {
        let a = WindowLifecycle.reopenAction(hasVisibleWindows: false,
                                             windows: [w("snapshots", visible: false, minimized: true),
                                                       w("main", visible: false, minimized: true)])
        #expect(a == .deminiaturize(1), "das Hauptfenster hat Vorrang")
    }

    @Test("Nur ein anderes Fenster minimiert: dieses zurückholen")
    func minimizedOther() {
        let a = WindowLifecycle.reopenAction(hasVisibleWindows: false,
                                             windows: [w("snapshots", visible: false, minimized: true)])
        #expect(a == .deminiaturize(0))
    }

    @Test("Hauptfenster erkennen: SwiftUI hängt evtl. Suffixe an die ID")
    func isMain() {
        #expect(WindowLifecycle.isMainWindow(identifier: "main"))
        #expect(WindowLifecycle.isMainWindow(identifier: "main-AppWindow-1"))
        #expect(!WindowLifecycle.isMainWindow(identifier: "snapshots"))
        #expect(!WindowLifecycle.isMainWindow(identifier: "mainly"))
        #expect(!WindowLifecycle.isMainWindow(identifier: nil))
    }

    @Test("Selbsttest-Argument: Schritte, Standard und unbekannte Schritte")
    func selftestArgs() {
        typealias S = WindowLifecycle.SelftestStep
        #expect(WindowLifecycle.selftestSteps(["DiskRings"]) == nil)
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close"]) == [S.close("main")])
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close", "--scan", "/usr"]) == [.close("main")])
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close", "snapshots,main"])
            == [.close("snapshots"), .close("main")])
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close", " min:main , ,dock:click"])
            == [.minimize("main"), .dockClick])
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close", "app:hide,hide:main,close:settings"])
            == [.hideApp, .orderOut("main"), .close("settings")])
        #expect(WindowLifecycle.selftestSteps(["DiskRings", "--selftest-close", "foo:bar"]) == [.close("main")],
                "nur unbekannte Schritte → Standard")
        #expect(S.dockClick.windowID == nil && S.minimize("snapshots").windowID == "snapshots")
    }
}
