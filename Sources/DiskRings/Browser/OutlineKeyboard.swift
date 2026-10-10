import DiskRingsCore
import SwiftUI

/// Tastaturbedienung der Listen (Detailliste, Vergleichsliste, „Größte
/// Veränderungen“). Die Regeln stehen in `OutlineNavigation` (Core, getestet);
/// hier wird nur die Taste übersetzt und der Befehl an die Liste gegeben.
///
/// Die Listen bleiben `ScrollView` + `LazyVStack` (siehe dev/DECISIONS.md);
/// sie werden mit `.focusable()` fokussierbar und reagieren per `onKeyPress`.
/// Leertaste (Übersicht) und die Menükürzel (⌘⌫, ⌘I, ⌘R …) wirken über die
/// Auswahl, die die Tastatur hier setzt.
enum OutlineKeyboard {
    /// Navigationstaste ohne ⌘/⌥/⌃ (sonst gehört sie dem Menü bzw. dem System).
    static func key(_ press: KeyPress) -> OutlineKey? {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch press.key {
        case .upArrow: return .up
        case .downArrow: return .down
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        default: return nil
        }
    }

    /// ⏎ ohne Modifikator.
    static func isReturn(_ press: KeyPress) -> Bool {
        press.key == .return && press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }

    /// Hintergrund einer Zeile: kräftiger, solange die Liste den Tastaturfokus hat
    /// (wie bei Finder-Listen), sonst wie bisher.
    static func rowBackground(selected: Bool, hovered: Bool, listFocused: Bool) -> Color {
        if selected { return Color.accentColor.opacity(listFocused ? 0.38 : 0.22) }
        return hovered ? Color.primary.opacity(0.07) : .clear
    }
}
