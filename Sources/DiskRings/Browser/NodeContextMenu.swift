import DiskRingsCore
import SwiftUI

/// Einträge des Kontextmenüs (SPEC 3.5), für Diagramm und Liste gleich.
///
/// M3 setzt nur „Hier hineinzoomen“ um. Für M4 genügt es, in
/// `NodeActions.perform` die übrigen Fälle zu implementieren und
/// `isImplemented` anzupassen; Menü, Tastenkürzel und Reihenfolge stehen hier.
enum NodeAction: CaseIterable, Identifiable {
    case revealInFinder, open, quickLook, zoomIn, copyPath, info, rescan, moveToTrash

    var id: Self { self }

    var title: String {
        switch self {
        case .revealInFinder: "Im Finder zeigen"
        case .open: "Öffnen"
        case .quickLook: "Quick Look"
        case .zoomIn: "Hier hineinzoomen"
        case .copyPath: "Pfad kopieren"
        case .info: "Informationen"
        case .rescan: "Diesen Ordner neu scannen"
        case .moveToTrash: "In den Papierkorb legen"
        }
    }

    var symbol: String {
        switch self {
        case .revealInFinder: "folder"
        case .open: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .zoomIn: "plus.magnifyingglass"
        case .copyPath: "doc.on.doc"
        case .info: "info.circle"
        case .rescan: "arrow.clockwise"
        case .moveToTrash: "trash"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .revealInFinder: KeyboardShortcut("r", modifiers: .command)
        case .quickLook: KeyboardShortcut(" ", modifiers: [])
        case .copyPath: KeyboardShortcut("c", modifiers: [.command, .option])
        case .info: KeyboardShortcut("i", modifiers: .command)
        case .rescan: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .moveToTrash: KeyboardShortcut(.delete, modifiers: .command)
        default: nil
        }
    }

    /// Trennlinie vor diesem Eintrag.
    var startsGroup: Bool { self == .zoomIn || self == .copyPath || self == .moveToTrash }
}

/// Ausführung der Aktionen. Platzhalter bis M4.
@MainActor
enum NodeActions {
    static func isImplemented(_ action: NodeAction) -> Bool { action == .zoomIn }

    static func isEnabled(_ action: NodeAction, node: Int32, state: AppState) -> Bool {
        guard let tree = state.tree, isImplemented(action) else { return false }
        switch action {
        case .zoomIn: return tree.node(node).isDirectory && node != state.focus && state.size(node) > 0
        default: return true
        }
    }

    static func perform(_ action: NodeAction, node: Int32, state: AppState) {
        switch action {
        case .zoomIn: state.navigate(to: node)
        default: break // M4: Finder, Öffnen, Quick Look, Pfad kopieren, Info, Teil-Rescan, Papierkorb
        }
    }
}

struct NodeContextMenu: View {
    let state: AppState
    let node: Int32

    var body: some View {
        if let tree = state.tree {
            Text(tree.name(of: node))
            ForEach(NodeAction.allCases) { action in
                if action.startsGroup { Divider() }
                let button = Button {
                    NodeActions.perform(action, node: node, state: state)
                } label: {
                    Label(NodeActions.isImplemented(action) ? action.title : action.title + " (folgt)",
                          systemImage: action.symbol)
                }
                .disabled(!NodeActions.isEnabled(action, node: node, state: state))
                if let s = action.shortcut { button.keyboardShortcut(s) } else { button }
            }
        }
    }
}
