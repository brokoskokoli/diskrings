import DiskRingsCore
import SwiftUI

// MARK: Kontextmenü „Mit KI analysieren“
//
// Ein Abschnitt vor „Neu scannen“, in der normalen Ansicht und im Vergleich
// (dort nur für Elemente des aktuellen Scans). Das Untermenü zeigt oben die in
// den Einstellungen ausgewählten Web-KIs und immer „Prompt kopieren“, in der
// GitHub-Variante darunter die gefundenen CLIs (interaktive Sitzung im
// Terminal), ganz unten „KI-Einstellungen …“ (Aufbau: `AIMenuPlan`).
// Siehe dev/DECISIONS.md („Mit KI analysieren“).

@MainActor
enum AIContextMenu {
    static let install: Void = {
        ContextMenuRegistry.register(ContextMenuSection(id: "ai", items: [item]), before: "rescan")
    }()

    static let item = ContextMenuItem(
        id: "ai.menu",
        title: { _, _ in L("ai.menu") },
        systemImage: "wand.and.stars",
        availability: { t, state in state.aiAvailability(for: t) },
        perform: { _, _ in },
        submenu: { t, state in state.aiMenuGroups(for: t) })
}

extension AppState {
    /// Gruppen des Untermenüs; Aufbau und Reihenfolge aus `AIMenuPlan` (Core).
    func aiMenuGroups(for _: ContextMenuTarget) -> [[ContextMenuItem]] {
        AIMenuPlan.groups(selection: prefs.aiSelection, sessions: aiMenuSessions).map { group in
            group.compactMap(aiMenuItem)
        }
    }

    /// Stand der CLI-Suche fürs Menü; `nil` in der Store-Variante und in der Sandbox.
    private var aiMenuSessions: AIMenuPlan.Sessions? {
        #if AISessions
        guard !isSandboxed else { return nil }
        if let tools = ai.tools, !ai.isSearching { return .found(tools.map(\.id)) }
        return .searching
        #else
        return nil
        #endif
    }

    private func aiMenuItem(_ entry: AIMenuEntry) -> ContextMenuItem? {
        func info(_ id: String, _ text: String, _ symbol: String) -> ContextMenuItem {
            ContextMenuItem(id: id, title: { _, _ in text }, systemImage: symbol,
                            availability: { _, _ in .disabled(text) }, perform: { _, _ in })
        }
        switch entry {
        case .web(let service):
            let prefill = service.handoff != .copyAndOpen
            return ContextMenuItem(
                id: "ai.\(service.id)",
                title: { _, _ in prefill ? L("ai.web.ask", service.name) : L("ai.web.copyOpen", service.name) },
                systemImage: prefill ? "safari" : "doc.on.clipboard",
                availability: { _, _ in .enabled },
                perform: { t, state in state.requestAI(.web(service), for: t) })
        case .copyPrompt:
            return ContextMenuItem(id: "ai.copy", title: { _, _ in L("ai.copyPrompt") }, systemImage: "doc.on.doc",
                                   availability: { _, _ in .enabled },
                                   perform: { t, state in state.requestAI(.copy, for: t) })
        case .sessionHeader:
            return info("ai.session.header", L("ai.session.header"), "terminal")
        case .sessionSearching:
            return info("ai.session.searching", L("ai.session.searching"), "hourglass")
        case .sessionNone:
            return info("ai.session.none", L("ai.session.none"), "questionmark.circle")
        case .sessionTool(let id):
            #if AISessions
            guard let inst = ai.tools?.first(where: { $0.id == id }) else { return nil }
            return ContextMenuItem(id: "ai.\(inst.id)", title: { _, _ in inst.tool.name }, systemImage: "apple.terminal",
                                   availability: { _, _ in .enabled },
                                   perform: { t, state in
                                       state.requestAI(.session(toolID: inst.id, toolName: inst.tool.name,
                                                                executable: inst.path), for: t)
                                   })
            #else
            _ = id
            return nil
            #endif
        case .settings:
            return ContextMenuItem(id: "ai.settings", title: { _, _ in L("ai.settingsLink") }, systemImage: "gearshape",
                                   availability: { _, _ in .enabled },
                                   perform: { _, state in state.openAISettings() })
        }
    }

    /// Einstellungen auf dem Reiter „KI“ öffnen.
    func openAISettings() {
        UserDefaults.standard.set(SettingsTab.ai.rawValue, forKey: "settings.selectedTab")
        ai.openSettings?()
    }
}
