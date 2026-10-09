import AppKit
import DiskRingsCore
import Foundation
import Observation

/// Zustand des Vergleichsmodus (SPEC 3.9): Modell, Ansicht, Fokus (als
/// Vergleichseintrag), Hover, Auswahl und Liste. Die Logik steckt im
/// `CompareModel` (Core); hier liegt nur, was die Oberfläche braucht.
/// Woraus ein Vergleich entstanden ist; bestimmt, ob er nach Änderungen am
/// aktuellen Baum (Papierkorb, Undo, Teil-Rescan) neu berechnet wird.
enum CompareSource {
    /// Gespeicherter Snapshot ↔ aktueller Scan (wird neu berechnet).
    case currentScan
    /// Zwei gespeicherte Snapshots (unabhängig vom aktuellen Baum).
    case snapshots
}

@MainActor
@Observable
final class CompareSession {
    enum Tab: String, CaseIterable, Identifiable {
        case contents, largest
        var id: Self { self }
        var title: String { self == .contents ? L("compare.tab.contents") : L("compare.tab.largest") }
    }

    let model: CompareModel
    /// Linke Seite („vorher“), z. B. „vor Xcode-Update“ oder „Snapshot vom …“.
    let oldTitle: String
    /// Rechte Seite („jetzt“), z. B. „Aktueller Scan“.
    let newTitle: String
    let comparesSnapshots: Bool
    let headline: CompareHeadline

    var view: CompareViewMode { didSet { relayout() } }
    private(set) var history = FocusHistory()
    private(set) var layout: SunburstLayout
    private(set) var options: SunburstOptions

    var hoverEntry: Int32?
    var hoverArc: Int?
    var hoverCenter = false
    var hoverLocation: CGPoint?
    var selected: Int32?
    var expanded: Set<Int32> = []
    var sort = CompareSort.byDeltaDescending
    var tab: Tab = .contents
    /// Tab „Größte Veränderungen“: Rückgang statt Zuwachs.
    var showShrink = false
    /// Bitte an die Liste, zu diesem Eintrag zu scrollen.
    var scrollRequest: Int32?
    /// `nil` nur in den Vorschaubildern (kein Neuberechnen).
    var source: CompareSource?

    init(model: CompareModel, oldTitle: String, newTitle: String, comparesSnapshots: Bool, options: SunburstOptions) {
        self.model = model
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.comparesSnapshots = comparesSnapshots
        self.headline = CompareHeadline(diff: model.diff, comparesSnapshots: comparesSnapshots)
        let v: CompareViewMode = model.hasGrowth ? .growth : .delta
        self.view = v
        self.options = options
        self.layout = model.layout(v, focusEntry: 0, options: options)
    }

    var focus: Int32 { history.current }
    var diff: SnapshotDiff { model.diff }
    var displayTree: CompareDisplayTree { model.displayTree(view) }

    func setOptions(_ o: SunburstOptions) {
        guard o != options else { return }
        options = o
        relayout()
    }

    func relayout() {
        layout = model.layout(view, focusEntry: focus, options: options)
        hoverArc = nil
    }

    /// Übernimmt Ansicht, Fokus, Historie, Auswahl, Sortierung und Tab eines
    /// vorherigen Vergleichs desselben Snapshots (nach Neuberechnung).
    func adopt(from old: CompareSession) {
        let map = CompareEntryMapping(from: old.diff, to: diff)
        source = old.source
        sort = old.sort
        tab = old.tab
        showShrink = old.showShrink
        options = old.options
        history = map.history(old.history)
        selected = old.selected.flatMap(map.map)
        expanded = Set(old.expanded.compactMap(map.map))
        view = old.view // löst relayout() aus
        relayout()
    }

    var canGoUp: Bool { focus != 0 }

    // MARK: Navigation

    func navigate(to e: Int32) {
        guard e != focus, model.diff.isDirectory(e) else { return }
        history.navigate(to: e)
        didChangeFocus()
    }

    func goBack() { if history.goBack() { didChangeFocus() } }
    func goForward() { if history.goForward() { didChangeFocus() } }

    func goUp() {
        // Im Diagramm kann der Fokus ein Eintrag sein, der dort fehlt; „nach
        // oben“ heißt dann: über den gezeigten Ordner hinaus.
        let shown = displayTree.entry(ofNode: layout.focus)
        if let p = model.parent(of: shown) { navigate(to: p) } else if focus != 0 { navigate(to: 0) }
    }

    private func didChangeFocus() {
        hoverEntry = nil
        hoverCenter = false
        relayout()
    }

    /// Wählt einen Eintrag aus (z. B. aus „Größte Veränderungen“): Liegt er
    /// nicht unter dem Fokus, wird in seinen Elternordner gezoomt; die Liste
    /// klappt bis dorthin auf und scrollt hin.
    func reveal(_ e: Int32) {
        if !model.isAncestor(focus, of: e) || e == focus, let p = model.parent(of: e) { navigate(to: p) }
        select(e)
    }

    func select(_ e: Int32?) {
        selected = e
        guard let e else { return }
        var p = model.parent(of: e)
        while let q = p, q != focus {
            expanded.insert(q)
            p = model.parent(of: q)
        }
        scrollRequest = e
    }

    // MARK: Diagramm

    func click(_ hit: SunburstHit) {
        switch hit {
        case .center: goUp()
        case .arc(let i):
            guard i < layout.arcs.count else { return }
            let arc = layout.arcs[i]
            switch arc.kind {
            case .node:
                guard let e = model.entry(for: arc, view: view) else { return }
                if arc.isDirectory {
                    selected = e
                    navigate(to: e)
                } else {
                    select(e)
                }
            case .aggregate, .remainder:
                let e = displayTree.entry(ofNode: arc.nodeIndex)
                if arc.nodeIndex != layout.focus { navigate(to: e) }
            case .unassigned: break
            }
        case .none: break
        }
    }

    func hoverDiagram(_ hit: SunburstHit, at location: CGPoint?) {
        hoverLocation = location
        switch hit {
        case .center:
            hoverArc = nil
            hoverEntry = nil
            hoverCenter = true
        case .arc(let i):
            hoverArc = i
            hoverCenter = false
            hoverEntry = model.entry(at: hit, layout: layout, view: view)
        case .none:
            hoverArc = nil
            hoverEntry = nil
            hoverCenter = false
        }
    }

    func hoverList(_ e: Int32?) {
        hoverLocation = nil
        hoverArc = nil
        hoverCenter = false
        hoverEntry = e
    }

    // MARK: Farben (gecacht, damit Hover nicht alle Arcs neu einfärbt)

    private struct ColorKey: Hashable {
        let view: CompareViewMode
        let focus: Int32
        let options: SunburstOptions
        let scheme: PaletteScheme
        let appearance: PaletteAppearance
    }

    @ObservationIgnored private var colorCache: [ColorKey: [DiskRingsCore.RGBColor]] = [:]

    func colors(palette: Palette) -> [DiskRingsCore.RGBColor] {
        let key = ColorKey(view: view, focus: layout.focus, options: layout.options, scheme: palette.scheme,
                           appearance: palette.appearance)
        if let c = colorCache[key], c.count == layout.arcs.count { return c }
        if colorCache.count > 8 { colorCache.removeAll() }
        let c = model.colors(for: layout, view: view, palette: palette)
        colorCache[key] = c
        return c
    }
}

// MARK: Vergleich starten und beenden

extension AppState {
    /// Aktuellen Scan mit einem gespeicherten Snapshot vergleichen
    /// (Toolbar „Vergleichen mit…“).
    func startCompare(with info: SnapshotInfo) {
        guard let current = currentSnapshot() else { return }
        let store = snapshots.store
        runCompare(oldTitle: SnapshotNaming.title(info.metadata), newTitle: L("compare.currentScan"), comparesSnapshots: false,
                   source: .currentScan) {
            SnapshotDiff(old: try store.load(info), new: current)
        }
    }

    /// Der aktuelle Baum als Snapshot (für „Snapshot ↔ aktueller Scan“).
    func currentSnapshot() -> Snapshot? {
        guard let tree, let summary else { return nil }
        let meta = SnapshotMetadata.current(for: summary, tree: tree, volume: volume,
                                            date: snapshots.currentScanDate ?? Date())
        return Snapshot(metadata: meta, tree: tree)
    }

    /// Zwei gespeicherte Snapshots ohne neuen Scan vergleichen (der ältere ist „vorher“).
    func compareSnapshots(_ a: SnapshotInfo, _ b: SnapshotInfo) {
        let (old, new) = a.metadata.date <= b.metadata.date ? (a, b) : (b, a)
        let store = snapshots.store
        runCompare(oldTitle: SnapshotNaming.title(old.metadata), newTitle: SnapshotNaming.title(new.metadata),
                   comparesSnapshots: true, source: .snapshots) {
            SnapshotDiff(old: try store.load(old), new: try store.load(new))
        }
    }

    /// Beendet den Vergleich. Ohne aktuellen Scan (zwei Snapshots, vom
    /// Startbildschirm aus verglichen) geht es zurück zum Startbildschirm
    /// statt in eine leere Hauptansicht.
    func endCompare() {
        compare = nil
        compareRunGate.invalidate()
        // Ein verworfener Lauf räumt seine Meldung nicht mehr selbst ab.
        snapshots.busy = nil
        if tree == nil, phase == .browsing {
            phase = .start
            refreshVolumes()
        }
    }

    /// Lädt und vergleicht im Hintergrund; danach ist der Vergleichsmodus aktiv.
    private func runCompare(oldTitle: String, newTitle: String, comparesSnapshots: Bool, source: CompareSource,
                            makeDiff: @escaping @Sendable () throws -> SnapshotDiff) {
        let mode = prefs.sizeMode
        let options = prefs.layoutOptions(unassigned: 0)
        let token = compareRunGate.begin()
        // Für „Snapshot ↔ aktueller Scan“: der Baum, der verglichen wird.
        let comparedTree = tree
        snapshots.busy = L("compare.busy.computing")
        Task {
            defer { if compareRunGate.isCurrent(token) { snapshots.busy = nil } }
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    CompareModel(diff: try makeDiff(), mode: mode)
                }.value
                // Inzwischen neuer Scan, zurück zum Start, Vergleich beendet
                // oder ein neuerer Vergleich: Ergebnis verwerfen.
                guard compareRunGate.isCurrent(token) else { return }
                if source == .currentScan, tree == nil || phase != .browsing { return }
                let session = CompareSession(model: model, oldTitle: oldTitle, newTitle: newTitle,
                                             comparesSnapshots: comparesSnapshots, options: options)
                session.source = source
                compare = session
                if phase == .start { phase = .browsing }
                // Baum während der Berechnung geändert (Papierkorb, Teil-Rescan):
                // gleich neu rechnen.
                if source == .currentScan, tree !== comparedTree { scheduleCompareRefresh() }
            } catch {
                guard compareRunGate.isCurrent(token) else { return }
                snapshots.errorMessage = L("compare.error", L10n.describe(error))
            }
        }
    }

    /// Synchron vergleichen (nur für die Vorschaubilder).
    func startCompareSynchronously(old: Snapshot, new: Snapshot, oldTitle: String, newTitle: String,
                                   comparesSnapshots: Bool) {
        let model = CompareModel(diff: SnapshotDiff(old: old, new: new), mode: prefs.sizeMode)
        compare = CompareSession(model: model, oldTitle: oldTitle, newTitle: newTitle,
                                 comparesSnapshots: comparesSnapshots, options: prefs.layoutOptions(unassigned: 0))
    }
}
