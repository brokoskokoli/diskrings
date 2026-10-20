import DiskRingsCore
import SwiftUI

// MARK: Kontextmenü „Mit KI analysieren“
//
// Ein Abschnitt vor „Neu scannen“, in der normalen Ansicht und im Vergleich
// (dort nur für Elemente des aktuellen Scans). Das Untermenü zeigt die in den
// Einstellungen ausgewählten Web-KIs, in der GitHub-Variante die gefundenen
// CLIs (interaktive Sitzung im Terminal) und immer „Prompt kopieren“.
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
    /// Gruppen des Untermenüs.
    func aiMenuGroups(for _: ContextMenuTarget) -> [[ContextMenuItem]] {
        let selection = prefs.aiSelection
        var groups: [[ContextMenuItem]] = []
        let web = selection.enabledWebServices().map { service in
            let prefill = service.handoff != .copyAndOpen
            return ContextMenuItem(
                id: "ai.\(service.id)",
                title: { _, _ in prefill ? L("ai.web.ask", service.name) : L("ai.web.copyOpen", service.name) },
                systemImage: prefill ? "safari" : "doc.on.clipboard",
                availability: { _, _ in .enabled },
                perform: { t, state in state.requestAI(.web(service), for: t) })
        }
        if !web.isEmpty { groups.append(web) }
        #if AISessions
        if !isSandboxed, let cli = aiSessionGroup(selection) { groups.append(cli) }
        #endif
        groups.append([
            ContextMenuItem(id: "ai.copy", title: { _, _ in L("ai.copyPrompt") }, systemImage: "doc.on.doc",
                            availability: { _, _ in .enabled },
                            perform: { t, state in state.requestAI(.copy, for: t) }),
            ContextMenuItem(id: "ai.settings", title: { _, _ in L("ai.settingsLink") }, systemImage: "gearshape",
                            availability: { _, _ in .enabled },
                            perform: { _, state in state.openAISettings() }),
        ])
        return groups
    }

    #if AISessions
    /// CLIs: Überschrift, gefundene und ausgewählte Werkzeuge, „Erneut suchen“.
    /// Sind alle gefundenen abgewählt, fehlt die Gruppe ganz.
    private func aiSessionGroup(_ selection: AIMenuSelection) -> [ContextMenuItem]? {
        func info(_ id: String, _ text: String, _ symbol: String) -> ContextMenuItem {
            ContextMenuItem(id: id, title: { _, _ in text }, systemImage: symbol,
                            availability: { _, _ in .disabled(text) }, perform: { _, _ in })
        }
        var items = [info("ai.session.header", L("ai.session.header"), "terminal")]
        if let tools = ai.tools, !ai.isSearching {
            if tools.isEmpty {
                items.append(info("ai.session.none", L("ai.session.none"), "questionmark.circle"))
            } else {
                let shown = tools.filter { selection.isEnabled($0.id) }
                if shown.isEmpty { return nil }
                items += shown.map { inst in
                    ContextMenuItem(id: "ai.\(inst.id)", title: { _, _ in inst.tool.name }, systemImage: "apple.terminal",
                                    availability: { _, _ in .enabled },
                                    perform: { t, state in
                                        state.requestAI(.session(toolID: inst.id, toolName: inst.tool.name,
                                                                 executable: inst.path), for: t)
                                    })
                }
            }
        } else {
            items.append(info("ai.session.searching", L("ai.session.searching"), "hourglass"))
        }
        items.append(ContextMenuItem(id: "ai.session.rescan", title: { _, _ in L("ai.session.rescan") },
                                     systemImage: "arrow.clockwise",
                                     availability: { _, state in state.ai.isSearching ? .disabled(L("ai.session.searching")) : .enabled },
                                     perform: { _, state in state.ai.detectTools(environment: state.environment) }))
        return items
    }
    #endif

    /// Einstellungen auf dem Reiter „KI“ öffnen.
    func openAISettings() {
        UserDefaults.standard.set(SettingsTab.ai.rawValue, forKey: "settings.selectedTab")
        ai.openSettings?()
    }
}
