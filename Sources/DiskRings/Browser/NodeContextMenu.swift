import DiskRingsCore
import SwiftUI

// MARK: Zentrale, erweiterbare Struktur des Kontextmenüs
//
// Diagramm, Liste (und künftig der Vergleichsmodus) bauen ihr Kontextmenü
// aus `ContextMenuRegistry.sections(for:state:)`. Die eingebauten Einträge
// aus SPEC 3.5 kommen aus `NodeAction` (Core: Titel, Symbol, Kürzel,
// Verfügbarkeit samt Begründung). Weitere Einträge, z. B. für Snapshots,
// werden als eigene Abschnitte registriert:
//
//     ContextMenuRegistry.register(ContextMenuSection(id: "snapshots", items: [
//         ContextMenuItem(id: "compare.showDelta", title: { _, _ in "Veränderung anzeigen" },
//                         systemImage: "chart.bar", availability: { _, _ in .enabled },
//                         perform: { target, state in … })
//     ]), before: "trash")
//
// Siehe docs/DECISIONS.md („Kontextmenü“).

/// Worauf ein Kontextmenü wirkt.
struct ContextMenuTarget: Equatable {
    /// Alle Ziele (bei Rechtsklick auf ein ausgewähltes Element die ganze Auswahl).
    let nodes: [Int32]
    /// Das angeklickte Element.
    let clicked: Int32
}

/// Ein Eintrag des Kontextmenüs.
struct ContextMenuItem: Identifiable {
    let id: String
    var title: @MainActor (ContextMenuTarget, AppState) -> String
    var systemImage: String
    var shortcut: ActionShortcut?
    /// Ausgegraut mit Begründung (Tooltip), z. B. für geschützte Pfade.
    var availability: @MainActor (ContextMenuTarget, AppState) -> ActionAvailability
    var perform: @MainActor (ContextMenuTarget, AppState) -> Void
    /// Begründung zusätzlich als graue Zeile unter dem Eintrag zeigen
    /// (Tooltips in Menüs erscheinen erst nach einer Verzögerung).
    var showsReasonInline = false

    init(id: String, title: @escaping @MainActor (ContextMenuTarget, AppState) -> String, systemImage: String,
         shortcut: ActionShortcut? = nil,
         availability: @escaping @MainActor (ContextMenuTarget, AppState) -> ActionAvailability,
         perform: @escaping @MainActor (ContextMenuTarget, AppState) -> Void, showsReasonInline: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.availability = availability
        self.perform = perform
        self.showsReasonInline = showsReasonInline
    }

    /// Eingebauter Eintrag aus SPEC 3.5.
    static func builtin(_ action: NodeAction) -> ContextMenuItem {
        ContextMenuItem(
            id: "builtin.\(action.rawValue)",
            title: { target, _ in action.title(count: target.nodes.count) },
            systemImage: action.symbolName,
            shortcut: action.shortcut,
            availability: { target, state in state.availability(action, targets: target.nodes) },
            perform: { target, state in state.perform(action, targets: target.nodes) },
            showsReasonInline: action == .moveToTrash)
    }
}

/// Abschnitt (zwischen Trennlinien).
struct ContextMenuSection: Identifiable {
    let id: String
    var items: [ContextMenuItem]
    /// Abschnitt nur unter dieser Bedingung zeigen (z. B. nur im Vergleichsmodus).
    var isVisible: @MainActor (ContextMenuTarget, AppState) -> Bool = { _, _ in true }
}

@MainActor
enum ContextMenuRegistry {
    /// IDs der eingebauten Abschnitte in dieser Reihenfolge:
    /// „open“, „navigate“, „info“, „rescan“, „trash“.
    static let builtinSections: [ContextMenuSection] = {
        var sections: [ContextMenuSection] = []
        let ids = ["open", "navigate", "info", "rescan", "trash"]
        var current: [ContextMenuItem] = []
        for action in NodeAction.allCases {
            if action.startsGroup, !current.isEmpty {
                sections.append(ContextMenuSection(id: ids[sections.count], items: current))
                current = []
            }
            current.append(.builtin(action))
        }
        sections.append(ContextMenuSection(id: ids[sections.count], items: current))
        return sections
    }()

    private static var extra: [(section: ContextMenuSection, before: String?)] = []

    /// Registriert einen zusätzlichen Abschnitt vor dem Abschnitt `before`
    /// (eine ID von oben oder eines anderen registrierten Abschnitts) bzw.
    /// am Ende. Ein Abschnitt mit derselben ID wird ersetzt.
    static func register(_ section: ContextMenuSection, before: String? = nil) {
        extra.removeAll { $0.section.id == section.id }
        extra.append((section, before))
    }

    static func unregister(_ id: String) {
        extra.removeAll { $0.section.id == id }
    }

    /// Alle sichtbaren Abschnitte für ein Ziel, in Anzeigereihenfolge.
    static func sections(for target: ContextMenuTarget, state: AppState) -> [ContextMenuSection] {
        var out = builtinSections
        for (s, before) in extra {
            if let b = before, let i = out.firstIndex(where: { $0.id == b }) { out.insert(s, at: i) } else { out.append(s) }
        }
        return out.filter { $0.isVisible(target, state) && !$0.items.isEmpty }
    }
}

/// Inhalt des Kontextmenüs (Diagramm und Liste gleich).
struct NodeContextMenu: View {
    let state: AppState
    let node: Int32

    var body: some View {
        if let tree = state.tree {
            let target = ContextMenuTarget(nodes: state.contextTargets(for: node), clicked: node)
            Text(target.nodes.count == 1 ? tree.name(of: node) : "\(target.nodes.count) Objekte")
            ForEach(ContextMenuRegistry.sections(for: target, state: state)) { section in
                Divider()
                ForEach(section.items) { item in
                    let availability = item.availability(target, state)
                    let button = Button {
                        item.perform(target, state)
                    } label: {
                        Label(item.title(target, state), systemImage: item.systemImage)
                    }
                    .disabled(!availability.isEnabled)
                    .help(availability.reason ?? "")
                    if let s = item.shortcut?.keyboardShortcut { button.keyboardShortcut(s) } else { button }
                    if item.showsReasonInline, !availability.isEnabled, let reason = availability.reason {
                        Text(reason).font(.caption)
                    }
                }
            }
        }
    }
}

extension ActionShortcut {
    /// SwiftUI-Tastenkürzel.
    var keyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent
        switch self.key {
        case .character(let c): key = KeyEquivalent(c)
        case .space: key = .space
        case .delete: key = .delete
        }
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(key, modifiers: m)
    }
}

/// Nachbildung des Kontextmenüs als normale View, nur für die
/// Vorschaubilder (ein echtes `NSMenu` lässt sich nicht offscreen rendern).
/// Nutzt dieselben Abschnitte, Titel, Kürzel und Verfügbarkeiten.
struct ContextMenuPreview: View {
    let state: AppState
    let node: Int32

    var body: some View {
        if let tree = state.tree {
            let target = ContextMenuTarget(nodes: state.contextTargets(for: node), clicked: node)
            VStack(alignment: .leading, spacing: 0) {
                Text(target.nodes.count == 1 ? tree.name(of: node) : "\(target.nodes.count) Objekte")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                ForEach(ContextMenuRegistry.sections(for: target, state: state)) { section in
                    Divider().padding(.vertical, 4)
                    ForEach(section.items) { item in
                        let a = item.availability(target, state)
                        HStack(spacing: 8) {
                            Image(systemName: item.systemImage).frame(width: 16)
                            Text(item.title(target, state))
                            Spacer(minLength: 24)
                            if let s = item.shortcut { Text(s.display).foregroundStyle(.secondary) }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(a.isEnabled ? .primary : .tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        if item.showsReasonInline, !a.isEnabled, let r = a.reason {
                            Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.leading, 36).padding(.trailing, 12).padding(.bottom, 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 300, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}
