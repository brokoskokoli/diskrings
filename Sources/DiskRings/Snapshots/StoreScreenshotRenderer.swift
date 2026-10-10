import AppKit
import DiskRingsCore
import SwiftUI

/// Screenshots für den Mac App Store: ganzer Fensterinhalt mit 1440 × 900
/// Punkten, Renderer-Skalierung 2 → genau 2880 × 1800 Pixel (16:10).
///
///     swift run DiskRings --store-screenshots <ordner> [--language de] [--appearance light|dark]
///
/// Ausschließlich Demo-Daten (`DemoTree.home(scale: 2)`, Wurzel `/Users/demo`,
/// erfundene Volume-Kennzahlen eines 994-GB-Volumes); es wird nichts gescannt
/// und weder die echte Snapshot-Ablage noch die echten Volumes gelesen.
@MainActor
enum StoreScreenshotRenderer {
    static let size = CGSize(width: 1440, height: 900)
    static let GB: UInt64 = 1_000_000_000
    /// Breite der Liste rechts: breit genug für „Nicht lesbare Systemdaten“ & Co.
    static let listWidth: Double = 520

    static func run(outputDirectory: String, scheme: ColorScheme) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        func shot<V: View>(_ view: V, _ name: String) {
            failures += SnapshotRenderer.renderWindow(view.frame(width: size.width, height: size.height),
                                                      scheme: scheme, to: dir, name: name)
        }

        let before = DemoTree.home(scale: 2)
        let after = DemoTree.home(scale: 2, afterChanges: true)
        let others = [
            ContainerVolume(name: "Preboot", device: "disk3s2", mountPoint: "/System/Volumes/Preboot",
                            roles: ["Preboot"], used: 10_900_000_000),
            ContainerVolume(name: "VM", device: "disk3s6", mountPoint: "/System/Volumes/VM", roles: ["VM"],
                            used: 8_600_000_000),
            ContainerVolume(name: "Recovery", device: "disk3s3", mountPoint: nil, roles: ["Recovery"],
                            used: 1_500_000_000),
        ]
        let othersUsed = others.reduce(0) { $0 + $1.used }
        /// 994-GB-Volume: Scan + andere Volumes + nicht lesbare Systemdaten + löschbar = belegt.
        func volume(scanned: UInt64, unreadable: UInt64, path: String = "/Users/demo") -> VolumeInfo {
            let purgeable = 28 * GB, total = 994 * GB
            let available = total - (scanned + othersUsed + unreadable + purgeable)
            return VolumeInfo(name: "Macintosh HD", path: path, uuid: "DEMO-VOLUME", totalCapacity: total,
                              availableCapacity: available, availableForImportantUsage: available + purgeable,
                              isRootFileSystem: true, isInternal: true)
        }
        let vBefore = volume(scanned: before.root.allocatedSize, unreadable: 22 * GB)
        let vNow = volume(scanned: after.root.allocatedSize, unreadable: 24 * GB)
        let protection = ProtectedPaths(home: "/Users/demo", appBundlePath: nil, volumeRoots: ["/"])

        func browsing(_ tree: ScanTree, _ v: VolumeInfo) -> AppState {
            let s = SnapshotRenderer.makeState(tree: tree, volume: v, otherVolumes: others)
            s.protection = protection
            s.prefs.listWidth = listWidth
            // Leere temporäre Ablage statt der echten unter ~/Library/Application Support.
            s.snapshots = SnapshotLibrary(store: SnapshotStore(baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("DiskRingsStoreScreenshots-\(UUID().uuidString)")))
            s.setResultForSnapshot(ScanResult.make(tree: tree, duration: 38.4))
            s.showSummary = false
            return s
        }

        // 01: ganzes Volume mit Systemdaten, löschbar und frei; Tooltip auf Library.
        let s1 = browsing(after, vNow)
        if let lib = after.index(ofPath: "Library") {
            hover(s1, node: lib, canvas: browserCanvas, tooltip: true)
            s1.selected = lib
        }
        shot(BrowserView(state: s1, frozenTime: .distantPast), "01-overview")

        // 02: hineingezoomt in Library, Caches aufgeklappt, Hover auf Developer in der Liste.
        let s2 = browsing(after, vNow)
        if let lib = after.index(ofPath: "Library") {
            s2.navigate(to: lib)
            s2.relayout(animated: false)
            if let caches = after.index(ofPath: "Library/Caches") {
                s2.expanded.insert(caches)
                s2.selected = caches
            }
            if let dev = after.index(ofPath: "Library/Developer") { s2.hoverList(dev) }
        }
        shot(BrowserView(state: s2, frozenTime: .distantPast), "02-drilldown")

        // 03/04: Vergleich eines Snapshots von vor vier Wochen mit dem aktuellen Scan.
        let oldMeta = SnapshotMetadata.current(for: ScanResult.make(tree: before, duration: 36.0), volume: vBefore,
                                               otherVolumes: others, name: L("store.demo.snapshotName"),
                                               date: date("2026-09-12 09:14"))
        let newMeta = SnapshotMetadata.current(for: ScanResult.make(tree: after, duration: 38.4), volume: vNow,
                                               otherVolumes: others, date: date("2026-10-09 17:20"))
        func comparing(_ view: CompareViewMode) -> (AppState, CompareSession) {
            let s = browsing(after, vNow)
            s.startCompareSynchronously(old: Snapshot(metadata: oldMeta, tree: before),
                                        new: Snapshot(metadata: newMeta, tree: after),
                                        oldTitle: L("store.demo.snapshotName"), newTitle: L("compare.currentScan"),
                                        comparesSnapshots: false)
            let c = s.compare!
            c.view = view
            return (s, c)
        }
        let (s3, c3) = comparing(.growth)
        c3.tab = .largest
        hoverLargest(c3)
        shot(BrowserView(state: s3, frozenTime: .distantPast), "03-compare-growth")

        let (s4, c4) = comparing(.delta)
        // Aufgeklappt: Projects (gewachsener Datensatz) und Movies (entfernte Filme).
        for p in ["Projects", "Movies"] {
            if let e = c4.diff.entry(forPath: "/Users/demo/" + p) { c4.expanded.insert(e) }
        }
        c4.selected = c4.diff.entry(forPath: "/Users/demo/Movies")
        shot(BrowserView(state: s4, frozenTime: .distantPast), "04-compare-delta")

        // 05: Kontextmenü (nachgebildet, siehe `ContextMenuPreview`) auf Downloads.
        let s5 = browsing(after, vNow)
        if let dl = after.index(ofPath: "Downloads") {
            s5.selected = dl
            let p = hover(s5, node: dl, canvas: browserCanvas, tooltip: false)
            // Fensterkoordinaten: Toolbar (≈ 37 pt) und Innenabstand des Diagramms (16 pt).
            let origin = CGPoint(x: 16 + p.x, y: 37 + 16 + p.y)
            shot(BrowserView(state: s5, frozenTime: .distantPast)
                .overlay(alignment: .topLeading) {
                    ContextMenuPreview(state: s5, node: dl).offset(x: origin.x, y: origin.y)
                }, "05-context-menu")
        } else {
            failures += 1
        }

        // 06: Startbildschirm mit erfundenen Volumes.
        let s6 = SnapshotRenderer.makeState(tree: nil, volume: nil, otherVolumes: [])
        s6.volumes = [
            volume(scanned: after.root.allocatedSize, unreadable: 24 * GB, path: "/"),
            VolumeInfo(name: "Backup", path: "/Volumes/Backup", totalCapacity: 2_000 * GB,
                       availableCapacity: 1_240 * GB, availableForImportantUsage: 1_240 * GB,
                       isRootFileSystem: false, isInternal: false),
            VolumeInfo(name: "Photos SSD", path: "/Volumes/Photos SSD", totalCapacity: 1_000 * GB,
                       availableCapacity: 318 * GB, availableForImportantUsage: 318 * GB,
                       isRootFileSystem: false, isInternal: false, isRemovable: true),
        ]
        s6.containerVolumes = ["/": others]
        s6.fullDiskAccess = .granted
        shot(StartView(state: s6), "06-start")

        return failures == 0 ? 0 : 1
    }

    /// Diagrammfläche der Hauptansicht (ohne Toolbar, Statusleiste, Liste und Innenabstand).
    static var browserCanvas: CGSize {
        CGSize(width: size.width - listWidth - 1 - 32, height: size.height - 37 - 28 - 32)
    }

    /// Hover auf das Segment eines Knotens; liefert den Punkt in der Diagrammfläche.
    @discardableResult
    static func hover(_ s: AppState, node: Int32, canvas: CGSize, tooltip: Bool) -> CGPoint {
        guard let l = s.layout, let i = l.arcs.firstIndex(where: { $0.kind == .node && $0.nodeIndex == node })
        else { return .zero }
        let arc = l.arcs[i]
        let g = SunburstView.geometry(for: canvas, rings: l.options.maxRings)
        let r = (g.innerRadius(ofRing: Int(arc.depth)) + g.outerRadius(ofRing: Int(arc.depth))) / 2
        let p = CGPoint(x: canvas.width / 2 + r * sin(arc.midAngle), y: canvas.height / 2 - r * cos(arc.midAngle))
        s.hoverDiagram(.arc(i), at: tooltip ? p : nil)
        return p
    }

    /// Hover auf das größte Segment im ersten Ring des Vergleichs.
    static func hoverLargest(_ c: CompareSession) {
        let ring1 = c.layout.ringRanges.first ?? 0 ..< 0
        guard let i = ring1.max(by: { c.layout.arcs[$0].span < c.layout.arcs[$1].span }) else { return }
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
