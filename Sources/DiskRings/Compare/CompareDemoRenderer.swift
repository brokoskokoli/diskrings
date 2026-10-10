import AppKit
import DiskRingsCore
import SwiftUI

/// Vorschaubilder des Vergleichsmodus und der Snapshot-Oberfläche:
///
///     swift run DiskRings --render-snapshots build/snapshots --compare-demo
///
/// Legt in einem temporären Ordner einen Beispielbaum an (`CompareDemo`),
/// scannt ihn, speichert Snapshots in einer **temporären** Ablage (nie in
/// ~/Library/Application Support/DiskRings), verändert den Baum, scannt neu
/// und rendert alle Ansichten hell und dunkel. Der temporäre Ordner wird
/// danach gelöscht. Die Volume-Kennzahlen sind fest vorgegeben, damit die
/// Kopfzeile reproduzierbar ist.
@MainActor
enum CompareDemoRenderer {
    static let MB: UInt64 = 1_000_000

    static func run(outputDirectory: String) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DiskRingsCompareDemo-\(UUID().uuidString)")
        defer {
            // Nur den eigenen temporären Ordner löschen.
            if temp.lastPathComponent.hasPrefix("DiskRingsCompareDemo-") { try? FileManager.default.removeItem(at: temp) }
        }
        do {
            return try render(temp: temp, out: out)
        } catch {
            FileHandle.standardError.write(Data("compare demo failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func render(temp: URL, out: URL) throws -> Int32 {
        let homeURL = temp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try CompareDemo.createInitial(at: homeURL.path)
        let engine = ScanEngine(options: ScanOptions())
        let before = try engine.scanBlocking(homeURL.path)
        let home = before.tree.rootPath // aufgelöst (/private/var/…)
        let store = SnapshotStore(baseDirectory: temp.appendingPathComponent("ablage"))

        // Feste Zeitpunkte und Volume-Kennzahlen (die Scan-Wurzel gilt als Volume-Wurzel).
        let snapDate = date("2026-10-02 09:14"), scanDate = date("2026-10-09 17:20")
        func volume(available: UInt64) -> VolumeInfo {
            VolumeInfo(name: "Macintosh HD", path: home, uuid: "DEMO-VOLUME", totalCapacity: 1_000 * MB,
                       availableCapacity: available, availableForImportantUsage: available + 20 * MB,
                       isRootFileSystem: true)
        }
        let v1 = volume(available: 600 * MB), v2 = volume(available: 540 * MB)

        // Ablage: ein älterer Stand ohne versteckte Dateien, ein unbenannter, der benannte Vergleichspartner.
        let hiddenOff = try ScanEngine(options: ScanOptions(includeHidden: false)).scanBlocking(home)
        let warnInfo = try store.save(hiddenOff, volume: v1, name: "without hidden files", date: date("2026-09-18 08:02"))
        try store.save(before, volume: v1, date: date("2026-09-25 19:45"))
        let info = try store.save(before, volume: v1, name: "before Xcode update", date: snapDate)

        try CompareDemo.applyChanges(at: home)
        let after = try engine.scanBlocking(home)
        let current = Snapshot(metadata: .current(for: after, volume: v2, date: scanDate), tree: after.tree)
        let laterInfo = try store.save(after, volume: v2, name: "after Xcode update", date: scanDate)

        func makeState() -> AppState {
            let s = SnapshotRenderer.makeState(tree: after.tree, volume: v2,
                                               unassigned: v2.unassigned(scanTotal: after.allocatedSize))
            s.setResultForSnapshot(after)
            s.showSummary = false
            s.snapshots = SnapshotLibrary(store: store)
            s.snapshots.refresh()
            return s
        }
        func comparing(_ view: CompareViewMode) throws -> (AppState, CompareSession) {
            let s = makeState()
            s.startCompareSynchronously(old: try store.load(info), new: current, oldTitle: "before Xcode update",
                                        newTitle: L("compare.currentScan"), comparesSnapshots: false)
            let c = s.compare!
            c.view = view
            return (s, c)
        }
        let size = CGSize(width: 1240, height: 800)
        var failures = 0

        for scheme in [ColorScheme.light, .dark] {
            let sfx = scheme == .dark ? "dark" : "light"
            func shot<V: View>(_ v: V, _ name: String, _ sz: CGSize? = size) {
                if let sz {
                    failures += SnapshotRenderer.renderWindow(v.frame(width: sz.width, height: sz.height),
                                                              scheme: scheme, to: out, name: "\(name)-\(sfx)")
                } else {
                    failures += SnapshotRenderer.renderWindow(v, scheme: scheme, to: out, name: "\(name)-\(sfx)")
                }
            }

            // 1. Wachstum an der Wurzel, Hover auf dem größten Segment.
            let (s1, c1) = try comparing(.growth)
            hoverLargest(c1, size: size)
            shot(BrowserView(state: s1, frozenTime: .distantPast), "compare-growth")

            // 2. Wachstum, hineingezoomt in den Elternordner des neuen Ordners.
            let (s2, c2) = try comparing(.growth)
            if let dl = c2.diff.entry(forPath: home + "/" + CompareDemo.newFolderParent) { c2.navigate(to: dl) }
            shot(BrowserView(state: s2, frozenTime: .distantPast), "compare-growth-downloads")

            // 3. Delta-Färbung mit aufgeklappter Liste (Music: entferntes Album).
            let (s3, c3) = try comparing(.delta)
            if let musik = c3.diff.entry(forPath: home + "/Music") { c3.expanded.insert(musik) }
            if let dl = c3.diff.entry(forPath: home + "/Downloads") {
                c3.expanded.insert(dl)
                c3.selected = dl
            }
            shot(BrowserView(state: s3, frozenTime: .distantPast), "compare-delta")
            // 3b. Dasselbe mit „Ohne Farbe unterscheiden“ (Schraffur und ±).
            shot(BrowserView(state: s3, frozenTime: .distantPast)
                .environment(\.forcedAccessibility, ForcedAccessibility(differentiateWithoutColor: true)), "compare-delta-nocolor")

            // 4. Tab „Größte Veränderungen“ (Wachstum) und Rückgang (Delta).
            let (s4, c4) = try comparing(.growth)
            c4.tab = .largest
            shot(BrowserView(state: s4, frozenTime: .distantPast), "compare-largest")
            let (s4b, c4b) = try comparing(.delta)
            c4b.tab = .largest
            c4b.showShrink = true
            shot(BrowserView(state: s4b, frozenTime: .distantPast), "compare-largest-shrink")

            // 5. Zwei Snapshots, einer mit anderen Scan-Optionen → Warnung.
            let s5 = makeState()
            s5.startCompareSynchronously(old: try store.load(warnInfo), new: try store.load(laterInfo),
                                         oldTitle: "without hidden files", newTitle: "after Xcode update",
                                         comparesSnapshots: true)
            s5.compare?.view = .delta
            shot(BrowserView(state: s5, frozenTime: .distantPast), "compare-two-snapshots-warning")

            // 6. Normale Hauptansicht mit dem Button „Vergleichen mit…“.
            shot(BrowserView(state: makeState(), frozenTime: .distantPast), "compare-browser-toolbar")

            // 7. Popup „Vergleichen mit…“ (jüngster passender vorausgewählt; der
            //    Snapshot des aktuellen Scans erscheint nicht).
            let s7 = makeState()
            s7.snapshots.didFinishScanForPreview(date: scanDate)
            shot(CompareSnapshotPicker(state: s7), "compare-picker", nil)

            // 8. Fenster „Snapshots“ mit zwei ausgewählten Einträgen.
            let s8 = makeState()
            shot(SnapshotsWindow(state: s8, initialSelection: [info.id, laterInfo.id]), "snapshots-window",
                 CGSize(width: 780, height: 300))

            // 8b. Dasselbe Fenster mit einer abgeschnittenen und einer unlesbaren
            //     Datei (nur in der temporären Ablage).
            let cut = try store.save(before, volume: v1, name: "truncated", date: date("2026-09-10 12:00"))
            let cutData = try Data(contentsOf: cut.url)
            try cutData.prefix(cutData.count - 100).write(to: cut.url)
            try Data("not a snapshot".utf8).write(to: cut.url.deletingLastPathComponent()
                .appendingPathComponent("20260901T080000000Z.drsnap"))
            let newer = try store.save(before, volume: v1, name: "from a newer version", date: date("2026-09-05 12:00"))
            var newerData = try Data(contentsOf: newer.url)
            newerData[8] = 2 // Formatversion 2
            try newerData.write(to: newer.url)
            let s8b = makeState()
            shot(SnapshotsWindow(state: s8b), "snapshots-window-damaged", CGSize(width: 780, height: 400))
            for d in try store.listDamaged() { try store.delete(d) }

            // 9. Dialog „Snapshot sichern“ und Einstellungen.
            shot(SnapshotNameSheet(title: L("snapshots.save.title"), message: L("snapshots.save.message", home),
                                   confirm: L("snapshots.save.confirm"), name: .constant("before macOS update")) { _ in }, "snapshot-save-sheet", nil)
            shot(SettingsView(prefs: makeState().prefs), "settings-snapshots", nil)

            // 10. Kontextmenü im Vergleich (nachgebildet): bestehender Ordner,
            //     entferntes Element, Vergleich zweier Snapshots.
            let (s10, c10) = try comparing(.delta)
            if let dl = c10.diff.entry(forPath: home + "/Downloads"),
               let gone = c10.diff.entry(forPath: home + "/Music/Album B"),
               let s5c = s5.compare, let musik = s5c.diff.entry(forPath: home + "/Music") {
                shot(HStack(alignment: .top, spacing: 24) {
                    CompareContextMenuPreview(state: s10, entry: dl)
                    CompareContextMenuPreview(state: s10, entry: gone)
                    CompareContextMenuPreview(state: s5, entry: musik)
                }
                .padding(24), "compare-contextmenu", nil)
            } else {
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// Hover auf das größte Segment im ersten Ring (für Tooltip und Hervorhebung).
    private static func hoverLargest(_ c: CompareSession, size: CGSize) {
        let ring1 = c.layout.ringRanges.first ?? 0 ..< 0
        guard let i = ring1.max(by: { c.layout.arcs[$0].span < c.layout.arcs[$1].span }) else { return }
        // Ungefähre Größe des Diagrammbereichs im Fenster.
        let canvas = CGSize(width: size.width - CompareView.listWidth - 33, height: size.height - 150)
        let g = SunburstView.geometry(for: canvas, rings: c.layout.options.maxRings)
        let arc = c.layout.arcs[i]
        let r = (g.innerRadius(ofRing: 1) + g.outerRadius(ofRing: 1)) / 2
        c.hoverDiagram(.arc(i), at: CGPoint(x: canvas.width / 2 + r * sin(arc.midAngle),
                                            y: canvas.height / 2 - r * cos(arc.midAngle)))
    }

    private static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s) ?? Date()
    }
}

extension SnapshotLibrary {
    /// Nur für die Vorschaubilder: Zeitpunkt des aktuellen Scans setzen,
    /// ohne automatisch zu speichern.
    func didFinishScanForPreview(date: Date) {
        markCurrentScan(date)
    }
}
