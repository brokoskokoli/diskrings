import Foundation

/// Verhalten der App beim Schließen von Fenstern und beim Klick aufs
/// Dock-Symbol (wie das Festplattendienstprogramm): Mit dem letzten sichtbaren
/// Fenster endet die App; ein Klick aufs Dock-Symbol ohne sichtbares Fenster
/// holt ein minimiertes Fenster zurück oder öffnet das Hauptfenster.
///
/// Die Entscheidungen sind hier ohne AppKit formuliert, damit sie testbar
/// sind; die App überträgt `NSWindow` in `WindowInfo`.
public enum WindowLifecycle {
    /// ID der Hauptfenster-Szene (`Window(…, id:)`).
    public static let mainWindowID = "main"

    public struct WindowInfo: Sendable, Equatable {
        public var identifier: String?
        public var isVisible: Bool
        public var isMiniaturized: Bool
        /// Panels, Popover- und Menüfenster können nicht Hauptfenster werden.
        public var canBecomeMain: Bool

        public init(identifier: String?, isVisible: Bool, isMiniaturized: Bool, canBecomeMain: Bool) {
            self.identifier = identifier
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.canBecomeMain = canBecomeMain
        }
    }

    public enum ReopenAction: Sendable, Equatable {
        /// Ein Fenster ist sichtbar; nichts zu tun.
        case none
        /// Das minimierte Fenster mit diesem Index zurückholen.
        case deminiaturize(Int)
        /// Das Hauptfenster öffnen.
        case openMain
    }

    /// Antwort auf `applicationShouldHandleReopen(_:hasVisibleWindows:)`.
    public static func reopenAction(hasVisibleWindows: Bool, windows: [WindowInfo]) -> ReopenAction {
        if hasVisibleWindows, windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { return .none }
        let minimized = windows.indices.filter { windows[$0].isMiniaturized }
        if let i = minimized.first(where: { isMainWindow(identifier: windows[$0].identifier) }) ?? minimized.first {
            return .deminiaturize(i)
        }
        return .openMain
    }

    /// SwiftUI setzt die Szenen-ID als Fenster-ID, bei manchen Versionen mit
    /// Suffix (z. B. `main-AppWindow-1`).
    public static func isMainWindow(identifier: String?) -> Bool {
        guard let id = identifier else { return false }
        return id == mainWindowID || id.hasPrefix(mainWindowID + "-")
    }

    /// Ein Schritt des versteckten Selbsttests `--selftest-close [schritte]`.
    public enum SelftestStep: Sendable, Equatable {
        /// Fenster schließen (`main`, `snapshots`, `settings`).
        case close(String)
        /// Fenster minimieren (`min:<id>`).
        case minimize(String)
        /// Fenster nur ausblenden, ohne es zu schließen (`hide:<id>`).
        case orderOut(String)
        /// App ausblenden wie mit ⌘H (`app:hide`).
        case hideApp
        /// Reopen-Hook aufrufen wie AppKit beim Klick aufs Dock-Symbol (`dock:click`).
        case dockClick

        /// Fenster, das der Schritt braucht (wird vorher geöffnet).
        public var windowID: String? {
            switch self {
            case .close(let id), .minimize(let id), .orderOut(let id): id
            case .hideApp, .dockClick: nil
            }
        }

        init?(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                self = .close(text)
                return
            }
            switch (parts[0], parts[1]) {
            case ("close", let id): self = .close(id)
            case ("min", let id): self = .minimize(id)
            case ("hide", let id): self = .orderOut(id)
            case ("app", "hide"): self = .hideApp
            case ("dock", "click"): self = .dockClick
            default: return nil
            }
        }
    }

    /// Verstecktes Testargument `--selftest-close [schritte]`: Die App öffnet
    /// die genannten Fenster, führt die Schritte (durch Komma getrennt) im
    /// Abstand von 1,5 s aus und protokolliert nach stderr, damit sich das
    /// Beenden ohne Bedienung prüfen lässt. Standard: nur `main` schließen.
    /// Unbekannte Schritte werden übergangen. `nil` = kein Selbsttest.
    public static func selftestSteps(_ arguments: [String]) -> [SelftestStep]? {
        guard let i = arguments.firstIndex(of: "--selftest-close") else { return nil }
        if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
            let steps = arguments[i + 1].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .compactMap(SelftestStep.init)
            if !steps.isEmpty { return steps }
        }
        return [.close(mainWindowID)]
    }
}
