import AppKit
import DiskRingsCore
import Foundation
import Observation

/// Gemeinsame Sicht auf Zoom- und Änderungs-Übergänge für den Renderer.
protocol LayoutTransition: Sendable {
    var from: SunburstLayout { get }
    var to: SunburstLayout { get }
    func frame(at t: Double, rings: Int) -> [DisplayArc]
}

extension ZoomTransition: LayoutTransition {}
extension EditTransition: LayoutTransition {}

/// Laufender Übergang des Diagramms (Zoom oder Änderung am Baum).
struct ActiveTransition {
    let id = UUID()
    let animation: any LayoutTransition
    /// Baum des Ausgangs-Layouts (für dessen Farben; nach einer Änderung ist
    /// das nicht mehr der aktuelle Baum).
    let fromTree: ScanTree
    let start: Date
    let duration: TimeInterval

    static let zoomDuration: TimeInterval = 0.3
    static let editDuration: TimeInterval = 0.45
    /// Für Aufrufer, die nur die Zoom-Dauer kennen (Vorschaubilder).
    static var duration: TimeInterval { zoomDuration }

    func progress(at date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(start) / duration))
    }
}

/// Kurzer Hinweis unten im Diagramm (Ergebnis eines Teil-Rescans, Papierkorb, Fehler).
struct Toast: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    let kind: Kind
    let message: String
    /// „Widerrufen“-Knopf (nach dem Papierkorb).
    var offersUndo = false
}

/// Zentraler Zustand der App (SPEC 6: ScanEngine → Snapshots → AppState → Views).
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable { case start, scanning, browsing }

    let prefs: Preferences
    var phase: Phase = .start

    // MARK: Startbildschirm
    var volumes: [VolumeInfo] = []
    var fullDiskAccess: FullDiskAccess.Status = .unknown

    // MARK: Scan
    private(set) var scanPath: String?
    private(set) var progress: ScanProgress?
    private(set) var result: ScanResult?
    var scanError: String?
    var showSummary = false
    /// Steuert den laufenden Scan; Ereignisse eines abgebrochenen oder ersetzten
    /// Scans kommen hier nicht mehr an (siehe `ScanController`).
    @ObservationIgnored private let scanner = ScanController()
    /// Optionen des Scans, aus dem der Baum stammt (Teil-Rescans nutzen dieselben).
    @ObservationIgnored private(set) var scanOptionsUsed = ScanOptions()

    // MARK: Baum und Navigation
    private(set) var tree: ScanTree?
    private(set) var history = FocusHistory()
    private(set) var volume: VolumeInfo?
    private(set) var unassigned: UInt64 = 0
    private(set) var layout: SunburstLayout?
    private(set) var transition: ActiveTransition?

    // MARK: Hover und Auswahl (Diagramm und Liste synchron)
    /// Arc unter der Maus (Index im aktuellen Layout).
    var hoverArc: Int?
    /// Knoten unter der Maus, aus dem Diagramm oder der Liste.
    var hoverNode: Int32?
    var hoverCenter = false
    var hoverLocation: CGPoint?
    /// Auswahl; in der Liste auch mehrfach (⌘/⇧-Klick).
    var selection = NodeSelection()
    /// Aufgeklappte Ordner in der Liste.
    var expanded: Set<Int32> = []
    /// Bitte an die Liste, zu diesem Knoten zu scrollen.
    var scrollRequest: Int32?

    // MARK: Aktionen (M4)
    /// Schutzliste (SPEC 3.6); einmal pro Start bestimmt.
    @ObservationIgnored var protection = ProtectedPaths()
    /// Dateizugriff für Papierkorb und Undo (austauschbar).
    @ObservationIgnored var fileTrasher: any FileTrashing = FileManager.default
    /// Offener Bestätigungsdialog für den Papierkorb.
    var trashRequest: TrashPlan?
    /// Rückgängig machbare Papierkorb-Vorgänge (⌘Z), jüngster zuletzt.
    private(set) var undoStack: [[TrashRecord]] = []
    /// Knoten im Info-Fenster (⌘I).
    var infoNode: Int32?
    var toast: Toast?

    // MARK: Teil-Rescan (SPEC 3.8)
    private(set) var rescanQueue = RescanQueue()
    /// Geschätzter Fortschritt je neu eingelesenem Pfad (-1 = unbestimmt).
    private(set) var rescanProgress: [String: Double] = [:]
    @ObservationIgnored private var rescanTokens: [UInt64: ScanCancellation] = [:]

    // MARK: Suche
    var searchVisible = false
    var searchQuery = "" { didSet { if searchQuery != oldValue { scheduleSearch() } } }
    private(set) var searchResult: TreeSearch.Result?
    private(set) var isSearching = false
    /// Ergebnisliste statt Detailliste anzeigen.
    var showSearchResults = false
    @ObservationIgnored private var searchGeneration = 0

    // MARK: Snapshots und Vergleich (SPEC 3.9, siehe Snapshots/ und Compare/)
    var snapshots = SnapshotLibrary()
    var compare: CompareSession?

    init(prefs: Preferences) {
        self.prefs = prefs
        scanner.handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .progress(let p): self.progress = p
            case .snapshot(let t): self.applySnapshot(t)
            case .finished(let r): self.finish(r)
            case .failed(let error):
                self.scanError = "\(error)"
                self.setTree(nil)
                self.phase = .start
            }
        }
    }

    var focus: Int32 { history.current }
    var isVolumeRoot: Bool { volume.map { tree?.rootPath == $0.path } ?? false }
    /// Der zuletzt gewählte Knoten (Hervorhebung im Diagramm, Scrollziel).
    var selected: Int32? {
        get { selection.primary }
        set { selection.select(newValue) }
    }

    // MARK: Startbildschirm

    func refreshVolumes() {
        volumes = VolumeInfo.mountedVolumes()
        fullDiskAccess = FullDiskAccess.status()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: FullDiskAccess.settingsURL) { NSWorkspace.shared.open(url) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scannen"
        panel.message = "Ordner oder Volume zum Scannen wählen"
        if panel.runModal() == .OK, let url = panel.url { startScan(url.path) }
    }

    // MARK: Scan

    func startScan(_ path: String) {
        cancelScan()
        cancelPartialRescans()
        pendingFocusPath = nil
        scanPath = path
        progress = nil
        result = nil
        scanError = nil
        showSummary = false
        undoStack = []
        clearSearch()
        compare = nil
        setTree(nil)
        phase = .scanning
        scanOptionsUsed = prefs.scanOptions
        scanner.start(path, options: scanOptionsUsed)
    }

    func cancelScan() {
        scanner.cancel()
        if phase == .scanning {
            phase = .start
            setTree(nil)
        }
    }

    /// Kompletter neuer Scan der Wurzel; der Fokus wird über den Pfad wiederhergestellt.
    func rescan() {
        guard let path = tree?.rootPath ?? scanPath else { return }
        let focusPath = tree.map { $0.path(of: focus) }
        startScan(path)
        pendingFocusPath = focusPath
    }

    @ObservationIgnored private var pendingFocusPath: String?

    func backToStart() {
        compare = nil
        cancelScan()
        cancelPartialRescans()
        setTree(nil)
        result = nil
        undoStack = []
        clearSearch()
        phase = .start
        refreshVolumes()
    }

    private func applySnapshot(_ t: ScanTree) {
        guard phase == .scanning else { return }
        setTree(t)
        // Volume schon während des Scans für die Statusleiste.
        if volume == nil { volume = VolumeInfo.forPath(t.rootPath) }
    }

    private func finish(_ r: ScanResult) {
        result = r
        let v = VolumeInfo.forPath(r.tree.rootPath)
        volume = v
        unassigned = (v.map { $0.path == r.tree.rootPath } ?? false) ? v!.unassigned(scanTotal: r.allocatedSize) : 0
        setTree(r.tree)
        if let p = pendingFocusPath, let i = r.tree.index(ofPath: p) { history = FocusHistory(root: i) }
        pendingFocusPath = nil
        phase = .browsing
        showSummary = true
        snapshots.didFinishScan(r, volume: v, retention: prefs.snapshots.retention)
        relayout(animated: false)
    }

    /// Setzt einen neuen Baum (Snapshot, Endergebnis, Fixture) und überträgt
    /// Fokus und Auswahl über die Pfade.
    func setTree(_ new: ScanTree?, unassigned: UInt64? = nil, volume: VolumeInfo?? = nil) {
        if let u = unassigned { self.unassigned = u }
        if let v = volume { self.volume = v }
        let old = tree
        tree = new
        transition = nil
        hoverArc = nil
        hoverCenter = false
        if let old, let new {
            func map(_ i: Int32) -> Int32? { Int(old.count) > Int(i) ? new.index(ofPath: old.path(of: i)) : nil }
            history = history.remapped(from: old, to: new)
            selection = selection.translated(map)
            hoverNode = nil
            expanded = Set(expanded.compactMap(map))
            infoNode = infoNode.flatMap(map)
        } else {
            history = FocusHistory()
            selection = NodeSelection()
            hoverNode = nil
            expanded = []
            infoNode = nil
        }
        if new == nil {
            self.unassigned = 0
            if unassigned == nil { self.volume = nil }
        }
        relayout(animated: false)
    }

    /// Übernimmt eine neue Baum-Version nach einer Änderung (Papierkorb,
    /// Teil-Rescan, Undo): Fokus, Auswahl, Historie und aufgeklappte Ordner
    /// werden per Index-Übersetzung nachgeführt, das Diagramm animiert die
    /// Änderung, „Nicht zugeordnet“ wird neu berechnet.
    func applyEdit(_ new: ScanTree, translate: (Int32) -> Int32?) {
        guard let old = tree else { return }
        let oldLayout = layout
        tree = new
        history = history.translated(from: old, by: translate)
        selection = selection.translated(translate)
        expanded = Set(expanded.compactMap(translate))
        infoNode = infoNode.flatMap(translate)
        if let r = searchResult {
            searchResult = TreeSearch.Result(matches: r.matches.compactMap(translate), total: r.total)
        }
        hoverArc = nil
        hoverNode = nil
        hoverCenter = false
        refreshUnassigned()
        let newLayout = SunburstLayout(tree: new, focus: focus, options: prefs.layoutOptions(unassigned: unassigned))
        if let oldLayout, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startTransition(EditTransition(from: oldLayout, to: newLayout, translate: translate), fromTree: old,
                            duration: ActiveTransition.editDuration)
        } else {
            transition = nil
        }
        layout = newLayout
    }

    /// Volume-Kennzahlen neu lesen und „Nicht zugeordnet“ neu berechnen.
    func refreshUnassigned() {
        guard let tree, let v = VolumeInfo.forPath(tree.rootPath) else { return }
        volume = v
        unassigned = v.path == tree.rootPath ? v.unassigned(scanTotal: tree.root.allocatedSize) : 0
    }

    // MARK: Layout

    func relayout(animated: Bool) {
        guard let tree else {
            layout = nil
            return
        }
        let new = SunburstLayout(tree: tree, focus: focus, options: prefs.layoutOptions(unassigned: unassigned))
        if animated, let old = layout, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startTransition(ZoomTransition(from: old, to: new, tree: tree), fromTree: tree,
                            duration: ActiveTransition.zoomDuration)
        } else {
            transition = nil
        }
        layout = new
        hoverArc = nil
    }

    private func startTransition(_ animation: any LayoutTransition, fromTree: ScanTree, duration: TimeInterval) {
        let t = ActiveTransition(animation: animation, fromTree: fromTree, start: Date(), duration: duration)
        transition = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            if self?.transition?.id == t.id { self?.transition = nil }
        }
    }

    // MARK: Navigation

    func navigate(to node: Int32) {
        guard let tree, node != focus, tree.node(node).isDirectory else { return }
        history.navigate(to: node)
        didChangeFocus()
    }

    func goBack() {
        guard history.goBack() else { return }
        didChangeFocus()
    }

    func goForward() {
        guard history.goForward() else { return }
        didChangeFocus()
    }

    func goUp() {
        guard let tree, history.goUp(in: tree) else { return }
        didChangeFocus()
    }

    private func didChangeFocus() {
        hoverNode = nil
        hoverCenter = false
        relayout(animated: true)
    }

    /// Klick im Diagramm (SPEC 3.4 „Interaktion“). Doppelklick auf eine
    /// Datei öffnet Quick Look.
    func click(_ hit: SunburstHit, clickCount: Int = 1) {
        guard let tree, let layout else { return }
        switch hit {
        case .center:
            goUp()
        case .arc(let i):
            let arc = layout.arcs[i]
            switch arc.kind {
            case .node:
                if arc.isDirectory, tree.node(arc.nodeIndex).size(prefs.sizeMode) > 0 {
                    selected = arc.nodeIndex
                    navigate(to: arc.nodeIndex)
                } else {
                    select(arc.nodeIndex)
                    if clickCount >= 2 { perform(.quickLook, targets: [arc.nodeIndex]) }
                }
            case .aggregate, .remainder:
                // In den Elternordner zoomen, damit die kleinen Elemente Platz bekommen.
                if arc.nodeIndex != focus { navigate(to: arc.nodeIndex) }
            case .unassigned:
                break
            }
        case .none:
            break
        }
    }

    /// Wählt einen Knoten aus, klappt die Liste bis dorthin auf und scrollt hin.
    func select(_ node: Int32?) {
        selected = node
        guard let node else { return }
        reveal(node)
    }

    /// Klappt die Liste bis zum Knoten auf und scrollt hin.
    func reveal(_ node: Int32) {
        guard let tree else { return }
        var p = tree.node(node).parent
        while p >= 0, p != focus {
            expanded.insert(p)
            p = tree.node(p).parent
        }
        scrollRequest = node
    }

    func hoverDiagram(_ hit: SunburstHit, at location: CGPoint?) {
        hoverLocation = location
        switch hit {
        case .center:
            hoverArc = nil
            hoverNode = nil
            hoverCenter = true
        case .arc(let i):
            hoverArc = i
            hoverCenter = false
            if let a = layout?.arcs[i], a.kind == .node { hoverNode = a.nodeIndex } else { hoverNode = nil }
        case .none:
            hoverArc = nil
            hoverNode = nil
            hoverCenter = false
        }
    }

    func hoverList(_ node: Int32?) {
        hoverLocation = nil
        hoverArc = nil
        hoverCenter = false
        hoverNode = node
    }

    // MARK: Aktionen (Kontextmenü, Hauptmenü, Tastenkürzel)

    var actionContext: ActionContext? {
        guard let tree else { return nil }
        return ActionContext(tree: tree, focus: focus, protection: protection, sizeMode: prefs.sizeMode,
                             isFullScanRunning: phase == .scanning, rescanningPaths: rescanQueue.paths,
                             crossMountPoints: scanOptionsUsed.crossMountPoints)
    }

    /// Ziele eines Kontextmenüs auf `node`: die ganze Auswahl, wenn der Knoten
    /// dazugehört, sonst nur er selbst (wie im Finder).
    func contextTargets(for node: Int32) -> [Int32] {
        selection.contains(node) ? selection.nodes : [node]
    }

    /// Ziele für Hauptmenü und Tastenkürzel: die Auswahl; „Neu scannen“ ohne
    /// Auswahl wirkt auf den Fokus.
    func commandTargets(for action: NodeAction) -> [Int32] {
        if selection.isEmpty, action == .rescan, tree != nil { return [focus] }
        return selection.nodes
    }

    func availability(_ action: NodeAction, targets: [Int32]) -> ActionAvailability {
        guard let c = actionContext else { return .disabled("Kein Scan") }
        return action.availability(targets: targets, context: c)
    }

    /// Führt eine Aktion aus. Die Verfügbarkeit (Schutzliste!) wird hier
    /// geprüft, nicht nur im Menü: So wirkt auch ein Tastenkürzel auf einen
    /// geschützten Pfad nicht (SPEC 9).
    func perform(_ action: NodeAction, targets: [Int32]) {
        guard let tree, availability(action, targets: targets).isEnabled else {
            NSSound.beep()
            return
        }
        let urls = targets.map { URL(fileURLWithPath: tree.path(of: $0)) }
        switch action {
        case .revealInFinder: FileActions.reveal(urls)
        case .open: FileActions.open(urls)
        case .quickLook: QuickLookController.shared.toggle(urls)
        case .zoomIn: navigate(to: targets[0])
        case .copyPath: FileActions.copyPaths(urls.map(\.path))
        case .info: infoNode = targets[0]
        case .rescan: startPartialRescan(targets[0])
        case .moveToTrash: requestTrash(targets)
        }
    }

    /// Aus dem Hauptmenü bzw. per Tastenkürzel. Steht der Cursor in einem
    /// Textfeld (Suche), gehören die Tasten dem Textfeld.
    func performCommand(_ action: NodeAction) {
        if FileActions.isEditingText {
            if action == .moveToTrash {
                NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            }
            return
        }
        perform(action, targets: commandTargets(for: action))
    }

    // MARK: Papierkorb (SPEC 3.6)

    func requestTrash(_ targets: [Int32]) {
        guard let tree else { return }
        switch TrashPlan.make(targets: targets, in: tree, protection: protection, sizeMode: prefs.sizeMode) {
        case .failure(let e):
            showToast(.error, e.message)
        case .success(let plan):
            if TrashConfirmation.needsConfirmation(plan, dontAskAgain: prefs.skipTrashConfirmation) {
                trashRequest = plan
            } else {
                performTrash(plan)
            }
        }
    }

    func confirmTrash(dontAskAgain: Bool) {
        guard let plan = trashRequest else { return }
        trashRequest = nil
        if dontAskAgain, plan.allowsDontAskAgain { prefs.skipTrashConfirmation = true }
        performTrash(plan)
    }

    func performTrash(_ plan: TrashPlan) {
        guard let tree else { return }
        let out = TrashService(fileManager: fileTrasher, protection: protection).trash(plan)
        if !out.removedPaths.isEmpty {
            let chain = tree.removingNodes(atPaths: out.removedPaths)
            applyEdit(chain.tree, translate: chain.translate)
        }
        if !out.trashed.isEmpty {
            undoStack.append(out.trashed)
            let what = out.trashed.count == 1 ? "„\(out.trashed[0].name)“" : "\(out.trashed.count) Objekte"
            showToast(.success, "\(what) in den Papierkorb gelegt (\(ByteFormat.signed(-Int64(clamping: out.removedSize))))",
                      offersUndo: true)
            rescanTrashFolders(out.trashed)
        }
        if let f = out.failures.first {
            let name = (f.path as NSString).lastPathComponent
            showToast(.error, "„\(name)“ nicht in den Papierkorb gelegt: \(f.message)")
        }
    }

    var canUndoTrash: Bool { !undoStack.isEmpty && tree != nil }

    var undoTitle: String {
        guard let last = undoStack.last else { return "Widerrufen" }
        return last.count == 1 ? "„\(last[0].name)“ zurücklegen" : "\(last.count) Objekte zurücklegen"
    }

    /// ⌘Z: zurückverschieben, dann den Elternordner neu einlesen (SPEC 3.6).
    func undoTrash() {
        guard let tree, let records = undoStack.popLast() else { return }
        let out = TrashService(fileManager: fileTrasher, protection: protection).restore(records)
        for p in out.restored {
            let parent = ScanEngine.nearestExistingIndex(of: p, in: tree)
            startPartialRescan(path: tree.path(of: parent), silentIfCovered: true)
        }
        rescanTrashFolders(records)
        if let f = out.failures.first {
            showToast(.error, "„\((f.path as NSString).lastPathComponent)“ nicht zurückgelegt: \(f.message)")
        } else if !out.restored.isEmpty {
            showToast(.info, out.restored.count == 1
                ? "„\((out.restored[0] as NSString).lastPathComponent)“ zurückgelegt"
                : "\(out.restored.count) Objekte zurückgelegt")
        }
    }

    /// Liegt der Papierkorb im gescannten Baum (z. B. ~/.Trash beim Scan von
    /// „/“ oder „~“), wird er neu eingelesen; sonst stimmte die Summe nicht.
    private func rescanTrashFolders(_ records: [TrashRecord]) {
        guard let tree else { return }
        let folders = Set(records.compactMap { $0.trashURL?.deletingLastPathComponent().path })
        for f in folders where tree.index(ofPath: f) != nil {
            startPartialRescan(path: f, silentIfCovered: true, announce: false)
        }
    }

    // MARK: Teil-Rescan (SPEC 3.8)

    func startPartialRescan(_ node: Int32) {
        guard let tree else { return }
        startPartialRescan(path: tree.path(of: node))
    }

    /// Rescan-Knopf der Toolbar: der fokussierte Ordner.
    func rescanFocus() {
        guard tree != nil else { return }
        perform(.rescan, targets: [focus])
    }

    func startPartialRescan(path: String, silentIfCovered: Bool = false, announce: Bool = true) {
        guard let tree else { return }
        switch rescanQueue.request(path, fullScanRunning: phase == .scanning) {
        case .blockedByFullScan:
            showToast(.info, "Während eines vollständigen Scans ist kein Teil-Rescan möglich")
        case .alreadyCovered(let p):
            if !silentIfCovered { showToast(.info, "„\((p as NSString).lastPathComponent)“ wird bereits neu gescannt") }
        case .start(let id, let cancelling):
            for c in cancelling {
                rescanTokens.removeValue(forKey: c)?.cancel()
            }
            rescanProgress = rescanProgress.filter { rescanQueue.paths.contains($0.key) }
            let previous = tree.index(ofPath: path).map { tree.node($0).allocatedSize } ?? 0
            rescanProgress[path] = PartialRescan.estimatedProgress(scannedBytes: 0, previousSize: previous) ?? -1
            let token = ScanCancellation()
            rescanTokens[id] = token
            let options = scanOptionsUsed
            let thread = Thread { [weak self] in
                let result = Result {
                    try PartialRescan.scan(path, options: options, cancellation: token, onProgress: { p in
                        let fraction = PartialRescan.estimatedProgress(scannedBytes: p.allocatedBytes,
                                                                        previousSize: previous) ?? -1
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.updateRescanProgress(id: id, path: path, fraction) }
                        }
                    })
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finishPartialRescan(id: id, path: path, result: result, announce: announce)
                    }
                }
            }
            thread.qualityOfService = .userInitiated
            thread.name = "DiskRings.PartialRescan"
            thread.start()
        }
    }

    private func updateRescanProgress(id: UInt64, path: String, _ fraction: Double) {
        guard rescanQueue.jobs.contains(where: { $0.id == id }) else { return }
        rescanProgress[path] = fraction
    }

    private func finishPartialRescan(id: UInt64, path: String, result: Result<ScanResult?, Error>, announce: Bool) {
        rescanTokens.removeValue(forKey: id)
        // Abgebrochen oder durch einen Vorfahren ersetzt: Ergebnis verwerfen.
        guard rescanQueue.finish(id) else { return }
        rescanProgress[path] = nil
        guard phase == .browsing, let tree else { return }
        let name = (path as NSString).lastPathComponent
        switch result {
        case .failure(let error):
            if !(error is CancellationError) { showToast(.error, "„\(name)“ konnte nicht neu gescannt werden: \(error)") }
        case .success(let scanned):
            guard let merge = PartialRescan.merge(scanned?.tree, path: path, into: tree) else {
                if scanned == nil, path == tree.rootPath {
                    showToast(.error, "Die Scan-Wurzel „\(name)“ existiert nicht mehr")
                }
                return
            }
            applyEdit(merge.tree, translate: merge.edit.translate)
            if announce { showToast(merge.removed ? .info : .success, merge.summary(prefs.sizeMode)) }
        }
    }

    func cancelPartialRescans() {
        for id in rescanQueue.cancelAll() { rescanTokens.removeValue(forKey: id)?.cancel() }
        rescanProgress = [:]
    }

    /// Fortschritt je Knoten des aktuellen Baums (für Diagramm und Liste).
    var rescanningNodes: [Int32: Double] {
        guard let tree, !rescanProgress.isEmpty else { return [:] }
        var out: [Int32: Double] = [:]
        for (p, f) in rescanProgress { if let i = tree.index(ofPath: p) { out[i] = f } }
        return out
    }

    // MARK: Hinweise

    func showToast(_ kind: Toast.Kind, _ message: String, offersUndo: Bool = false) {
        let t = Toast(kind: kind, message: message, offersUndo: offersUndo)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(offersUndo ? 8 : 5))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: Suche (Skizze 3.3)

    func toggleSearch() {
        searchVisible.toggle()
        if !searchVisible { clearSearch() }
    }

    func clearSearch() {
        searchGeneration += 1
        searchQuery = ""
        searchResult = nil
        isSearching = false
        showSearchResults = false
        searchVisible = false
    }

    private func scheduleSearch() {
        searchGeneration += 1
        let gen = searchGeneration
        let query = searchQuery
        guard let tree, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResult = nil
            isSearching = false
            showSearchResults = false
            return
        }
        isSearching = true
        showSearchResults = true
        let mode = prefs.sizeMode
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard self?.searchGeneration == gen else { return }
            let r = await Task.detached(priority: .userInitiated) {
                TreeSearch.search(query, in: tree, sizeMode: mode, limit: 300)
            }.value
            guard let self, self.searchGeneration == gen, self.tree === tree else { return }
            self.searchResult = r
            self.isSearching = false
        }
    }

    /// Sprung zu einem Treffer: Fokus auf den Elternordner, Treffer
    /// auswählen und in der Liste zeigen.
    func jump(to node: Int32) {
        guard let tree else { return }
        let parent = tree.node(node).parent
        if parent >= 0, parent != focus { navigate(to: parent) }
        showSearchResults = false
        select(node)
    }

    // MARK: Vorschaubilder

    /// Ergebnis setzen, ohne zu scannen (Vorschaubilder).
    func setResultInternal(_ r: ScanResult) {
        result = r
        scanPath = r.tree.rootPath
    }

    /// Scan-Ansicht mit einem Snapshot vortäuschen (Vorschaubilder).
    func simulateScanning(path: String, snapshot: ScanTree, progress p: ScanProgress) {
        scanPath = path
        setTree(snapshot)
        progress = p
        phase = .scanning
    }

    /// Laufenden Teil-Rescan vortäuschen (Vorschaubilder).
    func simulateRescan(path: String, fraction: Double) {
        _ = rescanQueue.request(path, fullScanRunning: false)
        rescanProgress[path] = fraction
    }

    /// Suchergebnis ohne Hintergrund-Task setzen (Vorschaubilder).
    func simulateSearch(_ query: String) {
        guard let tree else { return }
        searchVisible = true
        searchGeneration += 1
        searchQuery = query
        searchGeneration += 1
        searchResult = TreeSearch.search(query, in: tree, sizeMode: prefs.sizeMode, limit: 300)
        isSearching = false
        showSearchResults = true
    }

    // MARK: Farben (gecacht, damit Hover nicht jedes Mal alle Arcs neu einfärbt)

    private struct ColorKey: Hashable {
        let tree: ObjectIdentifier
        let focus: Int32
        let options: SunburstOptions
        let arcCount: Int
        let scheme: PaletteScheme
        let appearance: PaletteAppearance
    }

    @ObservationIgnored private var colorCache: [ColorKey: [DiskRingsCore.RGBColor]] = [:]

    /// Farben aller Arcs eines Layouts (das Layout ist durch Baum, Fokus und
    /// Optionen eindeutig bestimmt). `tree` ist der Baum des Layouts (nach
    /// einer Änderung für das Ausgangs-Layout der alte Baum).
    func colors(for layout: SunburstLayout, palette: Palette, tree layoutTree: ScanTree? = nil) -> [DiskRingsCore.RGBColor] {
        guard let tree = layoutTree ?? tree else { return [] }
        let key = ColorKey(tree: ObjectIdentifier(tree), focus: layout.focus, options: layout.options,
                           arcCount: layout.arcs.count, scheme: palette.scheme, appearance: palette.appearance)
        if let c = colorCache[key] { return c }
        if colorCache.count > 8 { colorCache.removeAll() }
        let c = palette.colors(for: layout, tree: tree)
        colorCache[key] = c
        return c
    }

    /// Größe eines Knotens im aktuellen Größenmodus.
    func size(_ node: Int32) -> UInt64 { tree?.node(node).size(prefs.sizeMode) ?? 0 }
}
