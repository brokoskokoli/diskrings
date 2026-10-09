import AppKit
import DiskRingsCore
import SwiftUI

/// Rendert Vorschaubilder der Oberfläche als PNG (CLAUDE.md: visuelle
/// Prüfung über `ImageRenderer`). Aufruf:
///
///     swift run DiskRings --render-snapshots build/snapshots [--scan /usr/share]
///
/// Erzeugt je Szene eine Hell- und eine Dunkel-Variante.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: String, scanPath: String?) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let demo = DemoTree.home()
        let demoVolume = VolumeInfo(name: "Macintosh HD", path: "/Users/demo", totalCapacity: 494_000_000_000,
                                    availableCapacity: 182_000_000_000,
                                    availableForImportantUsage: 196_000_000_000, isRootFileSystem: true)
        let demoUnassigned = demoVolume.unassigned(scanTotal: demo.root.allocatedSize)
        var failures = 0

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"

            // 1. Diagramm allein, Fixture-Baum, Hover auf dem größten Ordner.
            let s1 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            if let i = s1.layout?.arcs.firstIndex(where: { $0.kind == .node && $0.depth == 2 }) {
                let arc = s1.layout!.arcs[i]
                let g = SunburstView.geometry(for: CGSize(width: 720, height: 720), rings: 6)
                let r = (g.innerRadius(ofRing: 2) + g.outerRadius(ofRing: 2)) / 2
                let p = CGPoint(x: 360 + r * sin(arc.midAngle), y: 360 - r * cos(arc.midAngle))
                s1.hoverDiagram(.arc(i), at: p)
            }
            failures += render(SunburstView(state: s1, interactive: false, frozenTime: .distantPast)
                .frame(width: 720, height: 720), scheme: scheme, to: dir, name: "sunburst-demo-\(suffix)")

            // 2. Hauptansicht, Fixture-Baum, Fokus auf Library, eine Zeile ausgewählt.
            let s2 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            s2.showSummary = false
            if let lib = demo.index(ofPath: "Library") {
                s2.navigate(to: lib)
                s2.relayout(animated: false)
                if let caches = demo.index(ofPath: "Library/Caches") {
                    s2.expanded.insert(caches)
                    s2.selected = caches
                }
                if let dev = demo.index(ofPath: "Library/Developer") { s2.hoverList(dev) }
            }
            failures += renderWindow(BrowserView(state: s2, frozenTime: .distantPast).frame(width: 1180, height: 760),
                               scheme: scheme, to: dir, name: "main-demo-\(suffix)")

            // 3. Hauptansicht an der Wurzel mit „Nicht zugeordnet“ und Farbschema Dateityp.
            let s3 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            s3.prefs.paletteScheme = .fileType
            failures += renderWindow(BrowserView(state: s3, frozenTime: .distantPast).frame(width: 1180, height: 760),
                               scheme: scheme, to: dir, name: "main-demo-filetype-\(suffix)")

            // 4. Zoom-Animation in der Mitte des Übergangs.
            let s4 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            if let movies = demo.index(ofPath: "Library") {
                s4.navigate(to: movies)
            }
            if let tr = s4.transition {
                let mid = tr.start.addingTimeInterval(ActiveTransition.duration * 0.5)
                failures += render(SunburstView(state: s4, interactive: false, frozenTime: mid)
                    .frame(width: 600, height: 600), scheme: scheme, to: dir, name: "sunburst-zoom-\(suffix)")
            }

            // 5. Startbildschirm mit echten Volumes und Hinweis-Banner.
            let s5 = makeState(tree: nil, volume: nil, unassigned: 0)
            s5.volumes = VolumeInfo.mountedVolumes()
            s5.fullDiskAccess = .denied
            failures += renderWindow(StartView(state: s5).frame(width: 900, height: 640), scheme: scheme, to: dir,
                               name: "start-\(suffix)")

            // 5b. Startbildschirm mit erfundenem Volume (für README und Website:
            // keine echten Datenträgernamen).
            let s5b = makeState(tree: nil, volume: nil, unassigned: 0)
            let GB: UInt64 = 1_000_000_000
            s5b.volumes = [
                VolumeInfo(name: "Macintosh HD", path: "/", totalCapacity: 994 * GB, availableCapacity: 212 * GB,
                           availableForImportantUsage: 251 * GB, isRootFileSystem: true, isInternal: true),
            ]
            s5b.fullDiskAccess = .granted
            failures += renderWindow(StartView(state: s5b).frame(width: 900, height: 470), scheme: scheme, to: dir,
                                     name: "start-demo-\(suffix)")

            // 6. Einstellungen.
            let s6 = makeState(tree: nil, volume: nil, unassigned: 0)
            s6.prefs.paletteScheme = .fileType
            s6.prefs.excludedPaths = ["/Users/demo/Library/Caches", "/Volumes/Backup"]
            failures += renderWindow(SettingsView(prefs: s6.prefs), scheme: scheme, to: dir, name: "settings-\(suffix)")

            // 9. Kontextmenü (nachgebildet, siehe `ContextMenuPreview`): Datei,
            //    geschützter Ordner (~/Library) und Mehrfachauswahl.
            let demoProtection = ProtectedPaths(home: "/Users/demo", appBundlePath: nil, volumeRoots: ["/"])
            let s9 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            s9.protection = demoProtection
            if let file = demo.index(ofPath: "Documents/Rechnung 1.pdf"), let lib = demo.index(ofPath: "Library"),
               let d1 = demo.index(ofPath: "Downloads/Installer 1.dmg"),
               let d2 = demo.index(ofPath: "Downloads/Installer 2.dmg"),
               let d3 = demo.index(ofPath: "Downloads/Datei 1.zip") {
                let s9b = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
                s9b.protection = demoProtection
                s9b.selection = NodeSelection([d1, d2, d3])
                failures += renderWindow(
                    HStack(alignment: .top, spacing: 24) {
                        ContextMenuPreview(state: s9, node: file)
                        ContextMenuPreview(state: s9, node: lib)
                        ContextMenuPreview(state: s9b, node: d2)
                    }
                    .padding(24), scheme: scheme, to: dir, name: "contextmenu-\(suffix)")

                // 10. Papierkorb-Dialog: ein Ordner unter 1 GB (mit „Nicht mehr fragen“)
                //     und eine Mehrfachauswahl über 1 GB (ohne).
                let small = demo.childIndices(of: demo.index(ofPath: "Library/Caches") ?? 0)
                    .first { demo.node($0).allocatedSize < 1_000_000_000 } ?? file
                if case .success(let p1) = TrashPlan.make(targets: [small], in: demo, protection: demoProtection),
                   case .success(let p2) = TrashPlan.make(
                       targets: [demo.index(ofPath: "Documents/Archiv") ?? d1, d1, d2], in: demo,
                       protection: demoProtection) {
                    failures += renderWindow(
                        HStack(alignment: .top, spacing: 24) {
                            TrashConfirmationView(plan: p1, onCancel: {}, onConfirm: { _ in })
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .shadow(radius: 8)
                            TrashConfirmationView(plan: p2, onCancel: {}, onConfirm: { _ in })
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .shadow(radius: 8)
                        }
                        .padding(24)
                        .background(Color.gray.opacity(0.3)), scheme: scheme, to: dir, name: "trash-dialog-\(suffix)")
                }

                // 11. Info-Fenster.
                failures += renderWindow(NodeInfoView(state: s9, node: lib, onClose: {}), scheme: scheme, to: dir,
                                         name: "info-\(suffix)")
            }

            // 12. Teil-Rescan läuft (Library: bestimmter Fortschritt, Movies:
            //     unbestimmt), dazu der Hinweis eines fertigen Teil-Rescans.
            let s12 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            s12.showSummary = false
            s12.simulateRescan(path: "/Users/demo/Library", fraction: 0.6)
            s12.simulateRescan(path: "/Users/demo/Movies", fraction: -1)
            s12.showToast(.success, PartialRescan.summary(name: "Downloads", before: 9_800_000_000,
                                                         after: 6_300_000_000, removed: false))
            failures += renderWindow(BrowserView(state: s12, frozenTime: .distantPast).frame(width: 1180, height: 760),
                                     scheme: scheme, to: dir, name: "main-rescan-\(suffix)")

            // 13. Suche mit Trefferliste.
            let s13 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            s13.showSummary = false
            s13.simulateSearch("cache")
            failures += renderWindow(BrowserView(state: s13, frozenTime: .distantPast).frame(width: 1180, height: 760),
                                     scheme: scheme, to: dir, name: "main-search-\(suffix)")

            // 14. Animation nach dem Papierkorb (Mitte des Übergangs): Movies entfernt.
            let s14 = makeState(tree: demo, volume: demoVolume, unassigned: demoUnassigned)
            if let movies = demo.index(ofPath: "Movies") {
                let chain = demo.removingNodes([movies])
                s14.applyEdit(chain.tree, translate: chain.translate)
                if let tr = s14.transition {
                    let mid = tr.start.addingTimeInterval(tr.duration * 0.5)
                    failures += render(SunburstView(state: s14, interactive: false, frozenTime: mid)
                        .frame(width: 600, height: 600), scheme: scheme, to: dir, name: "sunburst-trash-anim-\(suffix)")
                }
            }

            // 7. Echter Scan.
            if let scanPath {
                do {
                    let result = try ScanEngine(options: ScanOptions()).scanBlocking(scanPath)
                    let vol = VolumeInfo.forPath(result.tree.rootPath)
                    let isRoot = vol?.path == result.tree.rootPath
                    let s7 = makeState(tree: result.tree, volume: vol,
                                       unassigned: isRoot ? vol!.unassigned(scanTotal: result.allocatedSize) : 0)
                    s7.setResultForSnapshot(result)
                    let slug = scanPath.split(separator: "/").joined(separator: "-")
                    failures += renderWindow(BrowserView(state: s7, frozenTime: .distantPast).frame(width: 1180, height: 760),
                                       scheme: scheme, to: dir, name: "main-\(slug.isEmpty ? "root" : slug)-\(suffix)")
                    failures += render(SunburstView(state: s7, interactive: false, frozenTime: .distantPast)
                        .frame(width: 720, height: 720), scheme: scheme, to: dir,
                        name: "sunburst-\(slug.isEmpty ? "root" : slug)-\(suffix)")
                    // Scan-Ansicht mit einem Live-Snapshot (nur Ordner, vorläufige Größen).
                    let s8 = makeState(tree: nil, volume: nil, unassigned: 0)
                    var snapshot: ScanTree?
                    _ = try ScanEngine(options: ScanOptions(progressInterval: 0.001)).scanBlocking(
                        scanPath, onSnapshot: { if snapshot == nil { snapshot = $0 } })
                    s8.simulateScanning(path: scanPath, snapshot: snapshot ?? result.tree,
                                        progress: ScanProgress.make(filesScanned: result.fileCount / 2,
                                                               directoriesScanned: result.directoryCount / 2,
                                                               allocatedBytes: result.allocatedSize / 2,
                                                               currentPath: scanPath + "/…", elapsed: 0.05))
                    failures += renderWindow(ScanningView(state: s8, frozenTime: .distantPast).frame(width: 1180, height: 700),
                                       scheme: scheme, to: dir, name: "scanning-\(suffix)")
                    // Scan, der auf einen Datenschutz-Dialog von macOS wartet.
                    s8.simulateScanning(path: scanPath, snapshot: snapshot ?? result.tree,
                                        progress: ScanProgress.make(filesScanned: result.fileCount / 2,
                                                                    directoriesScanned: result.directoryCount / 2,
                                                                    allocatedBytes: result.allocatedSize / 2,
                                                                    currentPath: scanPath + "/Downloads", elapsed: 7.4),
                                        stalled: true)
                    failures += renderWindow(ScanningView(state: s8, frozenTime: .distantPast).frame(width: 1180, height: 700),
                                       scheme: scheme, to: dir, name: "scanning-stalled-\(suffix)")
                } catch {
                    FileHandle.standardError.write(Data("Scan von \(scanPath) fehlgeschlagen: \(error)\n".utf8))
                    failures += 1
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    static func makeState(tree: ScanTree?, volume: VolumeInfo?, unassigned: UInt64) -> AppState {
        let defaults = UserDefaults(suiteName: "DiskRingsSnapshots-\(UUID().uuidString)")!
        let state = AppState(prefs: Preferences(defaults: defaults))
        state.setTree(tree, unassigned: unassigned, volume: .some(volume))
        state.phase = tree == nil ? .start : .browsing
        return state
    }

    /// Rendert eine View mit `ImageRenderer` (2×) als PNG. Gibt 0 bei Erfolg zurück.
    static func render<V: View>(_ view: V, scheme: ColorScheme, to dir: URL, name: String) -> Int {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        var ok = false
        appearance.performAsCurrentDrawingAppearance {
            let content = view
                .environment(\.colorScheme, scheme)
                // ImageRenderer löst dynamische NSColors nicht nach dem Modus auf.
                .background(scheme == .dark ? Color(white: 0.196) : Color(white: 0.925))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let cg = renderer.cgImage else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let url = dir.appendingPathComponent(name + ".png")
            do {
                try data.write(to: url)
                print(url.path)
                ok = true
            } catch {
                FileHandle.standardError.write(Data("Schreiben fehlgeschlagen: \(url.path)\n".utf8))
            }
        }
        return ok ? 0 : 1
    }
}

extension SnapshotRenderer {
    /// Rendert eine View über ein unsichtbares Fenster mit `NSHostingView`
    /// (2×). `ImageRenderer` kann AppKit-gestützte Bausteine wie Buttons,
    /// ScrollView, List oder Form nicht zeichnen (dort erscheinen nur
    /// Platzhalter); für ganze Ansichten ist dieser Weg daher nötig.
    static func renderWindow<V: View>(_ view: V, scheme: ColorScheme, to dir: URL, name: String) -> Int {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.safeAreaRegions = []
        var size = host.fittingSize
        if size.width < 10 || size.height < 10 { size = CGSize(width: 900, height: 600) }
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        // Layout und verzögerte Updates (LazyVStack, onAppear) abarbeiten lassen.
        for _ in 0 ..< 6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        var ok = false
        appearance.performAsCurrentDrawingAppearance {
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            let url = dir.appendingPathComponent(name + ".png")
            if (try? data.write(to: url)) != nil {
                print(url.path)
                ok = true
            }
        }
        window.orderOut(nil)
        return ok ? 0 : 1
    }
}

extension AppState {
    /// Nur für die Vorschaubilder: Ergebnis ohne echten Scan-Ablauf setzen.
    func setResultForSnapshot(_ r: ScanResult) {
        setResultInternal(r)
    }
}
