import AppKit
import DiskRingsCore
import Foundation
import Observation

/// Laufender Zoom-Übergang des Diagramms.
struct ActiveTransition {
    let id = UUID()
    let zoom: ZoomTransition
    let start: Date
    static let duration: TimeInterval = 0.3

    func progress(at date: Date) -> Double {
        min(1, max(0, date.timeIntervalSince(start) / Self.duration))
    }
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
    var selected: Int32?
    /// Aufgeklappte Ordner in der Liste.
    var expanded: Set<Int32> = []
    /// Bitte an die Liste, zu diesem Knoten zu scrollen.
    var scrollRequest: Int32?

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
        pendingFocusPath = nil
        scanPath = path
        progress = nil
        result = nil
        scanError = nil
        showSummary = false
        compare = nil
        setTree(nil)
        phase = .scanning
        scanner.start(path, options: prefs.scanOptions)
    }

    func cancelScan() {
        scanner.cancel()
        if phase == .scanning {
            phase = .start
            setTree(nil)
        }
    }

    func rescan() {
        guard let path = tree?.rootPath ?? scanPath else { return }
        // Fokus über den Pfad wiederherstellen, sobald der neue Baum da ist.
        let focusPath = tree.map { $0.path(of: focus) }
        startScan(path)
        pendingFocusPath = focusPath
    }

    @ObservationIgnored private var pendingFocusPath: String?

    func backToStart() {
        compare = nil
        cancelScan()
        setTree(nil)
        result = nil
        phase = .start
        refreshVolumes()
    }

    private func applySnapshot(_ t: ScanTree) {
        guard phase == .scanning else { return }
        setTree(t)
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
            history = history.remapped(from: old, to: new)
            selected = selected.flatMap { Int(old.count) > Int($0) ? new.index(ofPath: old.path(of: $0)) : nil }
            hoverNode = nil
            expanded = Set(expanded.compactMap { Int(old.count) > Int($0) ? new.index(ofPath: old.path(of: $0)) : nil })
        } else {
            history = FocusHistory()
            selected = nil
            hoverNode = nil
            expanded = []
        }
        if new == nil {
            self.unassigned = 0
            if unassigned == nil { self.volume = nil }
        }
        relayout(animated: false)
    }

    // MARK: Layout

    func relayout(animated: Bool) {
        guard let tree else {
            layout = nil
            return
        }
        let new = SunburstLayout(tree: tree, focus: focus, options: prefs.layoutOptions(unassigned: unassigned))
        if animated, let old = layout, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let t = ActiveTransition(zoom: ZoomTransition(from: old, to: new, tree: tree), start: Date())
            transition = t
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ActiveTransition.duration + 0.05))
                if self?.transition?.id == t.id { self?.transition = nil }
            }
        } else {
            transition = nil
        }
        layout = new
        hoverArc = nil
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

    /// Klick im Diagramm (SPEC 3.4 „Interaktion“).
    func click(_ hit: SunburstHit) {
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
        guard let tree, let node else { return }
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
    /// Optionen eindeutig bestimmt).
    func colors(for layout: SunburstLayout, palette: Palette) -> [DiskRingsCore.RGBColor] {
        guard let tree else { return [] }
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
