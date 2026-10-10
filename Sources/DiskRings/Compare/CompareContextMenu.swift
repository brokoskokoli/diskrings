import AppKit
import DiskRingsCore
import SwiftUI

// MARK: Kontextmenü im Vergleichsmodus
//
// Die Abschnitte werden über `ContextMenuRegistry` registriert (je einer
// vor dem entsprechenden eingebauten Abschnitt, die im Vergleich
// ausgeblendet sind). Ziele sind Vergleichseinträge; die Prüfung macht
// `CompareActions` (Core), ausgeführt wird auf `state.tree` über den Pfad.
// Siehe docs/DECISIONS.md („Integration M4/M6“).

@MainActor
enum CompareContextMenuSections {
    /// Einmalige Registrierung (beim ersten Kontextmenü im Vergleich).
    static let install: Void = {
        let groups: [(id: String, actions: [NodeAction])] = [
            ("open", [.revealInFinder, .open, .quickLook]),
            ("navigate", [.zoomIn]),
            ("info", [.copyPath, .info]),
            ("rescan", [.rescan]),
            ("trash", [.moveToTrash]),
        ]
        for g in groups {
            var items = g.actions.map { item($0) }
            if g.id == "navigate" { items.append(showInDiagram) }
            ContextMenuRegistry.register(
                ContextMenuSection(id: "compare.\(g.id)", items: items, isVisible: { t, _ in t.isCompare }),
                before: g.id)
        }
    }()

    private static func item(_ action: NodeAction) -> ContextMenuItem {
        ContextMenuItem(
            id: "compare.\(action.rawValue)",
            title: { t, _ in action.title(count: t.compareEntries?.count ?? 1) },
            systemImage: action.symbolName,
            shortcut: action.shortcut,
            availability: { t, state in state.compareAvailability(action, entries: t.compareEntries ?? []) },
            perform: { t, state in
                if let entries = state.currentCompareEntries(for: t) { state.performCompare(action, entries: entries) }
            },
            showsReasonInline: action == .moveToTrash)
    }

    /// Für Zeilen aus „Größte Veränderungen“: in den Elternordner zoomen und auswählen.
    private static let showInDiagram = ContextMenuItem(
        id: "compare.showInDiagram",
        title: { _, _ in L("compare.showInChart") },
        systemImage: "scope",
        availability: { t, state in
            guard state.compare != nil, t.compareEntries?.count == 1 else { return .disabled(L("reason.singleItemOnly")) }
            return .enabled
        },
        perform: { t, state in
            guard let e = state.currentCompareEntries(for: t)?.first else { return }
            state.compare?.reveal(e)
        })
}

extension AppState {
    /// Ziel eines Kontextmenüs auf einen Vergleichseintrag.
    func compareContextTarget(for entry: Int32) -> ContextMenuTarget? {
        guard compare != nil else { return nil }
        let nodes = compareActionContext.flatMap { CompareActions.nodes(forEntries: [entry], context: $0) } ?? []
        return ContextMenuTarget(nodes: nodes, clicked: nodes.first ?? -1, tree: tree, compareEntries: [entry],
                                 diff: compare?.diff)
    }

    func compareMenuHeader(_ entry: Int32) -> String {
        guard let d = compare?.diff, entry >= 0, Int(entry) < d.count else { return "" }
        let name = d.name(of: entry)
        return d.status(entry) == .removed ? L("compare.removedName", name) : name
    }

    var compareActionContext: CompareActionContext? {
        guard let session = compare else { return nil }
        let fromScan = session.source != .snapshots && !session.comparesSnapshots
        return CompareActionContext(diff: session.diff, focusEntry: session.focus, sizeMode: session.model.mode,
                                    comparesSnapshots: !fromScan, current: fromScan ? actionContext : nil)
    }

    func compareAvailability(_ action: NodeAction, entries: [Int32]) -> ActionAvailability {
        guard let c = compareActionContext else { return .disabled(L("reason.noCompare")) }
        return CompareActions.availability(action, entries: entries, context: c)
    }

    /// Führt eine Aktion im Vergleich aus; die Verfügbarkeit wird wie in
    /// `perform` noch einmal geprüft (Schutzliste, SPEC 9).
    func performCompare(_ action: NodeAction, entries: [Int32]) {
        guard let session = compare, let c = compareActionContext,
              CompareActions.availability(action, entries: entries, context: c).isEnabled else {
            NSSound.beep()
            return
        }
        let paths = entries.map { session.diff.path(of: $0) }
        switch action {
        case .zoomIn:
            session.navigate(to: entries[0])
        case .copyPath:
            FileActions.copyPaths(paths)
        case .revealInFinder, .open, .quickLook, .info, .rescan, .moveToTrash:
            if let nodes = CompareActions.nodes(forEntries: entries, context: c) {
                perform(action, targets: nodes)
            } else {
                // Zwei Snapshots: nur Finder, Öffnen, Quick Look über den Pfad.
                let urls = paths.map { URL(fileURLWithPath: $0) }
                switch action {
                case .revealInFinder: FileActions.reveal(urls)
                case .open: FileActions.open(urls)
                case .quickLook: QuickLookController.shared.toggle(urls)
                default: NSSound.beep()
                }
            }
        }
    }

    // MARK: Hauptmenü „Objekt“ und Tastenkürzel (normale Ansicht oder Vergleich)

    /// Ziele im Vergleich: der ausgewählte Eintrag; „Neu scannen“ ohne Auswahl
    /// wirkt auf den Fokus des Vergleichs.
    func compareCommandEntries(for action: NodeAction) -> [Int32] {
        guard let session = compare else { return [] }
        if let s = session.selected { return [s] }
        return action == .rescan ? [session.focus] : []
    }

    func commandTitle(_ action: NodeAction) -> String {
        let count = compare != nil ? compareCommandEntries(for: action).count : commandTargets(for: action).count
        return action.title(count: count)
    }

    func commandAvailability(_ action: NodeAction) -> ActionAvailability {
        if compare != nil { return compareAvailability(action, entries: compareCommandEntries(for: action)) }
        return availability(action, targets: commandTargets(for: action))
    }

    /// Gibt es überhaupt ein Ziel? (Leertaste für Quick Look.)
    func hasCommandTargets(for action: NodeAction) -> Bool {
        compare != nil ? !compareCommandEntries(for: action).isEmpty : !commandTargets(for: action).isEmpty
    }

    // MARK: Navigation (Menü „Gehe zu“, Wischgesten): wirkt im Vergleich auf den Vergleich

    var canNavigateBack: Bool { compare?.history.canGoBack ?? history.canGoBack }
    var canNavigateForward: Bool { compare?.history.canGoForward ?? history.canGoForward }
    var canNavigateUp: Bool {
        if let c = compare { return c.canGoUp }
        return tree != nil && focus != ScanTree.rootIndex
    }

    func navigateBack() { if let c = compare { c.goBack() } else { goBack() } }
    func navigateForward() { if let c = compare { c.goForward() } else { goForward() } }
    func navigateUp() { if let c = compare { c.goUp() } else { goUp() } }
    func navigateToRoot() { if let c = compare { c.navigate(to: 0) } else { navigate(to: ScanTree.rootIndex) } }

    // MARK: Neuberechnung nach Änderungen am Baum

    /// Nach Papierkorb, Undo oder Teil-Rescan: ein laufender Vergleich
    /// „Snapshot ↔ aktueller Scan“ wird mit dem neuen Baum neu berechnet
    /// (mehrere Änderungen kurz nacheinander nur einmal). Ansicht, Fokus und
    /// Auswahl bleiben über die Pfade erhalten.
    func scheduleCompareRefresh() {
        guard let session = compare, session.source == .currentScan else { return }
        compareRefreshGeneration &+= 1
        let generation = compareRefreshGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == compareRefreshGeneration, compare === session,
                  let current = currentSnapshot() else { return }
            let old = session.diff.old
            let mode = session.model.mode
            snapshots.busy = L("compare.busy.updating")
            let model = await Task.detached(priority: .userInitiated) {
                CompareModel(diff: SnapshotDiff(old: old, new: current), mode: mode)
            }.value
            snapshots.busy = nil
            // Inzwischen beendet, ersetzt oder erneut geändert: verwerfen.
            guard generation == compareRefreshGeneration, compare === session else { return }
            let fresh = CompareSession(model: model, oldTitle: session.oldTitle, newTitle: session.newTitle,
                                       comparesSnapshots: session.comparesSnapshots, options: session.options)
            fresh.adopt(from: session)
            compare = fresh
        }
    }
}

/// Kontextmenü auf einen Vergleichseintrag (Diagramm, Liste, „Größte Veränderungen“).
struct CompareContextMenu: View {
    let state: AppState
    let entry: Int32

    var body: some View {
        let _: Void = CompareContextMenuSections.install
        if let target = state.compareContextTarget(for: entry) {
            ContextMenuItems(state: state, target: target, header: state.compareMenuHeader(entry))
        }
    }
}

/// Nachbildung für die Vorschaubilder.
struct CompareContextMenuPreview: View {
    let state: AppState
    let entry: Int32

    var body: some View {
        let _: Void = CompareContextMenuSections.install
        if let target = state.compareContextTarget(for: entry) {
            ContextMenuPreviewBody(state: state, target: target, header: state.compareMenuHeader(entry))
        }
    }
}
