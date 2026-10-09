@testable import DiskRingsCore
import Foundation
import Testing

/// Kleiner In-Memory-Baum: /Users/demo mit Library (Caches/a, Caches/b),
/// Movies (film.mov) und notiz.txt.
func smallTree(rootPath: String = "/Users/demo") -> ScanTree {
    var b = ScanTreeBuilder(rootName: (rootPath as NSString).lastPathComponent)
    let lib = b.directory("Library")
    let caches = b.directory("Caches", in: lib)
    b.file("a.cache", size: 3_000_000, in: caches)
    b.file("b.cache", size: 1_000_000, in: caches)
    b.file("prefs.plist", size: 10_000, in: lib)
    let movies = b.directory("Movies")
    b.file("film.mov", size: 9_000_000, in: movies)
    b.file("notiz.txt", size: 4_000)
    b.directory("leer")
    return b.build(rootPath: rootPath)
}

@Suite("Auswahlmodell")
struct NodeSelectionTests {
    @Test("Klick, ⌘-Klick und ⇧-Klick")
    func clicks() {
        var s = NodeSelection()
        #expect(s.isEmpty && s.primary == nil)
        s.select(5)
        #expect(s.nodes == [5] && s.primary == 5)
        s.toggle(8)
        #expect(s.nodes == [5, 8] && s.primary == 8)
        s.toggle(5)
        #expect(s.nodes == [8])
        s.select(nil)
        #expect(s.isEmpty)

        let visible: [Int32] = [1, 4, 2, 9, 7]
        s.select(4)
        s.extend(to: 7, visible: visible)
        #expect(Set(s.nodes) == [4, 2, 9, 7] && s.primary == 7)
        // Erneuter ⇧-Klick vom selben Anker aus verkleinert den Bereich.
        s.extend(to: 2, visible: visible)
        #expect(Set(s.nodes) == [4, 2] && s.primary == 2)
        // Rückwärts.
        s.extend(to: 1, visible: visible)
        #expect(Set(s.nodes) == [1, 4] && s.primary == 1)
        // Unsichtbarer Anker: wie einfacher Klick.
        var t = NodeSelection([42])
        t.extend(to: 9, visible: visible)
        #expect(t.nodes == [9])
    }

    @Test("Übersetzen und oberste Knoten")
    func translateAndTopLevel() throws {
        let tree = smallTree()
        let lib = try #require(tree.index(ofPath: "Library"))
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        let a = try #require(tree.index(ofPath: "Library/Caches/a.cache"))
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let s = NodeSelection([a, film, lib, caches])
        #expect(s.topLevel(in: tree) == [film, lib])
        let t = s.translated { $0 == a ? nil : $0 + 100 }
        #expect(t.nodes == [film + 100, lib + 100, caches + 100])
        #expect(t.anchor == caches + 100)
    }
}

@Suite("Mehrfaches Entfernen und Index-Übersetzung")
struct TreeEditChainTests {
    @Test("removingNodes entfernt mehrere Knoten, überspringt Nachfahren und übersetzt Indizes")
    func removeMany() throws {
        let tree = smallTree()
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        let a = try #require(tree.index(ofPath: "Library/Caches/a.cache"))
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let notiz = try #require(tree.index(ofPath: "notiz.txt"))
        let prefs = try #require(tree.index(ofPath: "Library/prefs.plist"))
        let total = tree.root.allocatedSize
        let chain = tree.removingNodes([caches, a, film, ScanTree.rootIndex])
        #expect(chain.edits.count == 2)
        let t = chain.tree
        expectValidTree(t)
        #expect(t.root.allocatedSize == total - 4_000_000 - 9_000_000)
        #expect(chain.allocatedDelta == -13_000_000)
        #expect(chain.translate(a) == nil && chain.translate(caches) == nil && chain.translate(film) == nil)
        #expect(chain.translate(notiz).map { t.path(of: $0) } == "/Users/demo/notiz.txt")
        #expect(chain.translate(prefs).map { t.path(of: $0) } == "/Users/demo/Library/prefs.plist")
        #expect(chain.translate(ScanTree.rootIndex) == ScanTree.rootIndex)
        // Über Pfade.
        let byPath = tree.removingNodes(atPaths: ["/Users/demo/Movies", "/Users/demo/gibtsnicht"])
        #expect(byPath.edits.count == 1)
        #expect(byPath.tree.index(ofPath: "Movies") == nil)
    }

    @Test("Viele Entfernungen mit Kompaktierung: Übersetzung bleibt korrekt")
    func removeWithCompaction() throws {
        var b = ScanTreeBuilder(rootName: "r")
        for i in 0 ..< 40 { b.file("f\(i)", size: UInt64(1000 + i)) }
        let tree = b.build(rootPath: "/r")
        let keep = try #require(tree.index(ofPath: "f39"))
        let victims = (0 ..< 30).compactMap { tree.index(ofPath: "f\($0)") }
        let chain = tree.removingNodes(victims)
        #expect(chain.edits.contains { $0.compacted })
        expectValidTree(chain.tree)
        #expect(chain.tree.root.childCount == 10)
        #expect(chain.translate(keep).map { chain.tree.name(of: $0) } == "f39")
    }

    @Test("FocusHistory.translated: entfernter Fokus fällt auf den Elternordner zurück")
    func historyTranslate() throws {
        let tree = smallTree()
        let lib = try #require(tree.index(ofPath: "Library"))
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        let movies = try #require(tree.index(ofPath: "Movies"))
        var h = FocusHistory()
        h.navigate(to: movies)
        h.navigate(to: lib)
        h.navigate(to: caches)
        let chain = tree.removingNodes([caches])
        let h2 = h.translated(from: tree, by: chain.translate)
        let t = chain.tree
        #expect(t.path(of: h2.current) == "/Users/demo/Library")
        // Der Zurück-Stapel enthielt Library als letzten Eintrag; der ist jetzt der Fokus selbst.
        #expect(h2.backStack.map { t.path(of: $0) } == ["/Users/demo", "/Users/demo/Movies"])
    }
}

/// Papierkorb in einem temporären Verzeichnis: verschiebt nach `<trash>/<name>`
/// (mit Zähler bei Kollision) und zählt die Aufrufe.
final class TempTrash: FileTrashing, @unchecked Sendable {
    let trashDir: String
    var trashCalls: [String] = []
    var failNext: Error?
    var reportNoURL = false

    init(_ dir: String) {
        trashDir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func trashItem(at url: URL) throws -> URL? {
        trashCalls.append(url.path)
        if let e = failNext {
            failNext = nil
            throw e
        }
        var dst = URL(fileURLWithPath: trashDir).appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = URL(fileURLWithPath: trashDir).appendingPathComponent("\(url.lastPathComponent) \(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dst)
        return reportNoURL ? nil : dst
    }

    func moveItem(at src: URL, to dst: URL) throws { try FileManager.default.moveItem(at: src, to: dst) }
    func itemExists(atPath path: String) -> Bool { FileManager.default.itemExists(atPath: path) }
}

@Suite("Papierkorb: Plan, Bestätigung, Ausführung, Undo", .timeLimit(.minutes(2)))
struct TrashTests {
    let noProtection = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: [])

    @Test("Plan: Summen, oberste Knoten, Texte")
    func plan() throws {
        let tree = smallTree()
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        let a = try #require(tree.index(ofPath: "Library/Caches/a.cache"))
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let p1 = try TrashPlan.make(targets: [caches], in: tree, protection: noProtection).get()
        #expect(p1.items.count == 1 && p1.totalSize == 4_000_000 && p1.totalFiles == 2)
        #expect(p1.title == "„Caches“ in den Papierkorb legen?")
        #expect(p1.message.hasPrefix("Caches · 4,0\u{00A0}MB · 2 Dateien"))
        #expect(p1.message.contains("/Users/demo/Library/Caches"))
        let p2 = try TrashPlan.make(targets: [a, caches, film], in: tree, protection: noProtection).get()
        #expect(p2.items.map(\.name) == ["Caches", "film.mov"])
        #expect(p2.totalSize == 13_000_000 && p2.totalFiles == 3)
        #expect(p2.title == "2 Objekte in den Papierkorb legen?")
        #expect(p2.message.hasPrefix("Insgesamt 13,0\u{00A0}MB · 3 Dateien"))
        let p3 = try TrashPlan.make(targets: [film], in: tree, protection: noProtection).get()
        #expect(p3.message.hasPrefix("film.mov · 9,0\u{00A0}MB\n"))
    }

    @Test("Plan: Scan-Wurzel, geschützte Pfade, tote Knoten und leere Auswahl werden abgelehnt")
    func planRejects() throws {
        let tree = smallTree()
        let lib = try #require(tree.index(ofPath: "Library"))
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let prot = ProtectedPaths(home: "/Users/demo", appBundlePath: nil, volumeRoots: ["/"])
        #expect(TrashPlan.make(targets: [], in: tree, protection: prot) == .failure(.empty))
        #expect(TrashPlan.make(targets: [0], in: tree, protection: noProtection)
            == .failure(.scanRoot("/Users/demo")))
        // ~/Library als Ganzes; auch zusammen mit einem erlaubten Element.
        guard case .failure(.protected(_, .homeLibrary)) = TrashPlan.make(targets: [film, lib], in: tree, protection: prot)
        else { Issue.record("~/Library hätte abgelehnt werden müssen"); return }
        #expect(TrashPlan.make(targets: [9999], in: tree, protection: prot) == .failure(.notLive))
        let removed = tree.removingNode(at: film).tree
        #expect(TrashPlan.make(targets: [film], in: removed, protection: prot) == .failure(.notLive))
    }

    @Test("„Nicht mehr fragen“ nur unter 1 GB, auch als Summe bei Mehrfachauswahl")
    func confirmation() {
        func plan(_ sizes: [UInt64], logical: [UInt64]? = nil) -> TrashPlan {
            TrashPlan(items: sizes.enumerated().map { i, s in
                TrashItem(node: Int32(i + 1), path: "/x/\(i)", name: "\(i)", isDirectory: false, allocatedSize: s,
                          logicalSize: logical?[i] ?? s, fileCount: 1)
            })
        }
        let small = plan([999_999_999])
        #expect(small.allowsDontAskAgain)
        #expect(!TrashConfirmation.needsConfirmation(small, dontAskAgain: true))
        #expect(TrashConfirmation.needsConfirmation(small, dontAskAgain: false))
        let big = plan([1_000_000_000])
        #expect(!big.allowsDontAskAgain)
        #expect(TrashConfirmation.needsConfirmation(big, dontAskAgain: true))
        let sum = plan([600_000_000, 500_000_000])
        #expect(!sum.allowsDontAskAgain)
        #expect(TrashConfirmation.needsConfirmation(sum, dontAskAgain: true))
        // Sparse-Datei: logisch groß, belegt klein → zählt als groß.
        let sparse = plan([4096], logical: [5_000_000_000])
        #expect(!sparse.allowsDontAskAgain)
    }

    @Test("Ausführung im temporären Papierkorb, Baum nachführen, Undo und Rescan des Elternordners")
    func trashAndUndo() throws {
        let fx = try Fixture()
        try fx.file("data/weg/a.bin", size: 200_000)
        try fx.file("data/weg/b.bin", size: 100_000)
        try fx.file("data/datei.bin", size: 50_000)
        try fx.file("rest/c.bin", size: 300_000)
        let trash = TempTrash(fx.path(".papierkorb-test"))
        var options = ScanOptions(workerCount: 2)
        options.excludedPaths = [trash.trashDir]
        let engine = ScanEngine(options: options)
        let t0 = try engine.scanBlocking(fx.root).tree
        let rootBefore = t0.root.allocatedSize
        let weg = try #require(t0.index(ofPath: "data/weg"))
        let datei = try #require(t0.index(ofPath: "data/datei.bin"))
        let plan = try TrashPlan.make(targets: [weg, datei], in: t0, protection: noProtection).get()
        let service = TrashService(fileManager: trash, protection: noProtection)
        let out = service.trash(plan)
        #expect(out.failures.isEmpty)
        #expect(out.trashed.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fx.path("data/weg")))
        #expect(FileManager.default.fileExists(atPath: trash.trashDir + "/weg/a.bin"))

        let chain = t0.removingNodes(atPaths: out.removedPaths)
        let t1 = chain.tree
        expectValidTree(t1)
        #expect(t1.root.allocatedSize == rootBefore - plan.totalSize)
        expectEquivalent(t1, try engine.scanBlocking(fx.root).tree)

        // Undo: zurücklegen, dann den Elternordner neu einlesen.
        let restored = service.restore(out.trashed)
        #expect(restored.failures.isEmpty && restored.restored.count == 2)
        #expect(FileManager.default.fileExists(atPath: fx.path("data/weg/b.bin")))
        let r = try engine.rescanBlocking(path: fx.path("data/weg"), in: t1)
        #expect(r.tree.root.allocatedSize == rootBefore)
        expectEquivalent(r.tree, try engine.scanBlocking(fx.root).tree)
    }

    @Test("Geschützte Pfade lehnt auch der Dienst selbst ab (nicht nur das Menü)")
    func serviceRefusesProtected() throws {
        let fx = try Fixture()
        try fx.file("home/Library/x.bin", size: 1000)
        let trash = TempTrash(fx.path("trash"))
        let prot = ProtectedPaths(home: fx.path("home"), appBundlePath: nil, volumeRoots: [])
        let plan = TrashPlan(items: [
            TrashItem(node: 1, path: fx.path("home/Library"), name: "Library", isDirectory: true,
                      allocatedSize: 1000, logicalSize: 1000, fileCount: 1),
            TrashItem(node: 2, path: fx.path("home"), name: "home", isDirectory: true,
                      allocatedSize: 1000, logicalSize: 1000, fileCount: 1),
        ])
        let out = TrashService(fileManager: trash, protection: prot).trash(plan)
        #expect(out.trashed.isEmpty)
        #expect(out.failures.count == 2)
        #expect(out.failures.allSatisfy { $0.message.hasPrefix("Geschützt") })
        #expect(trash.trashCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fx.path("home/Library/x.bin")))
    }

    @Test("Fehlerfälle: verschwundenes Element, Fehler beim Verschieben, Undo-Konflikte")
    func failures() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        try fx.file("b.bin", size: 1000)
        try fx.file("c.bin", size: 1000)
        let trash = TempTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection)
        func item(_ name: String) -> TrashItem {
            TrashItem(node: 1, path: fx.path(name), name: name, isDirectory: false, allocatedSize: 1000,
                      logicalSize: 1000, fileCount: 1)
        }
        trash.failNext = CocoaError(.fileWriteNoPermission)
        let out = service.trash(TrashPlan(items: [item("a.bin"), item("fehlt.bin"), item("b.bin")]))
        #expect(out.failures.map(\.path) == [fx.path("a.bin")])
        #expect(out.missing == [fx.path("fehlt.bin")])
        #expect(out.trashed.map(\.originalPath) == [fx.path("b.bin")])
        #expect(out.removedPaths == [fx.path("b.bin"), fx.path("fehlt.bin")])
        #expect(FileManager.default.fileExists(atPath: fx.path("a.bin")))

        // Undo-Konflikt: Am alten Ort liegt wieder etwas → nicht überschreiben.
        try fx.file("b.bin", size: 5)
        let r1 = service.restore(out.trashed)
        #expect(r1.restored.isEmpty && r1.failures.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: fx.path("b.bin"))[.size] as? Int == 5)
        // Ohne bekannten Ort im Papierkorb.
        let r2 = service.restore([TrashRecord(originalPath: fx.path("x"), trashURL: nil, name: "x", allocatedSize: 0)])
        #expect(r2.failures.first?.message == "Ort im Papierkorb unbekannt")
        // Aus dem Papierkorb verschwunden.
        let r3 = service.restore([TrashRecord(originalPath: fx.path("y"), trashURL: URL(fileURLWithPath: fx.path("trash/gibtsnicht")),
                                              name: "y", allocatedSize: 0)])
        #expect(r3.failures.first?.message == "Nicht mehr im Papierkorb")
        // Elternordner fehlt.
        let c = try #require(service.trash(TrashPlan(items: [item("c.bin")])).trashed.first)
        var moved = c
        moved.originalPath = fx.path("neu/ordner/c.bin")
        #expect(service.restore([moved]).failures.first?.message == "Der Elternordner existiert nicht mehr")
    }

    @Test("Echter Papierkorb (FileManager): nur eine selbst angelegte Temp-Datei, danach wieder entfernt")
    func realTrash() throws {
        let fx = try Fixture()
        let marker = "DiskRingsTest-\(UUID().uuidString).bin"
        try fx.file(marker, size: 4096)
        let service = TrashService(fileManager: FileManager.default, protection: ProtectedPaths())
        let plan = TrashPlan(items: [TrashItem(node: 1, path: fx.path(marker), name: marker, isDirectory: false,
                                               allocatedSize: 4096, logicalSize: 4096, fileCount: 1)])
        let out = service.trash(plan)
        guard let record = out.trashed.first, let url = record.trashURL else {
            // Ohne Papierkorb (z. B. in einer Sandbox) gibt es nichts aufzuräumen.
            withKnownIssue("Papierkorb in dieser Umgebung nicht verfügbar: \(out.failures)") {
                Issue.record("kein Papierkorb")
            }
            return
        }
        // Aufräumen in jedem Fall: nur genau die eigene Datei im Papierkorb.
        defer {
            if url.lastPathComponent.hasPrefix("DiskRingsTest-"), FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        #expect(url.path.contains("/.Trash"))
        #expect(url.lastPathComponent.hasPrefix("DiskRingsTest-"))
        #expect(!FileManager.default.fileExists(atPath: fx.path(marker)))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Undo legt die Datei zurück.
        let r = service.restore([record])
        #expect(r.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fx.path(marker)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Noch einmal in den Papierkorb und dort wieder entfernen.
        let again = service.trash(plan)
        if let u2 = again.trashed.first?.trashURL, u2.lastPathComponent.hasPrefix("DiskRingsTest-") {
            try FileManager.default.removeItem(at: u2)
            #expect(!FileManager.default.fileExists(atPath: u2.path))
        }
    }
}

@Suite("Verfügbarkeit der Kontextmenü-Einträge")
struct NodeActionTests {
    @Test("Reihenfolge, Titel und Tastenkürzel wie SPEC 3.5")
    func catalog() {
        #expect(NodeAction.allCases.map(\.title) == [
            "Im Finder zeigen", "Öffnen", "Quick Look", "Hier hineinzoomen", "Pfad kopieren", "Informationen",
            "Diesen Ordner neu scannen", "In den Papierkorb legen",
        ])
        #expect(NodeAction.revealInFinder.shortcut?.display == "⌘R")
        #expect(NodeAction.copyPath.shortcut?.display == "⌥⌘C")
        #expect(NodeAction.info.shortcut?.display == "⌘I")
        #expect(NodeAction.rescan.shortcut?.display == "⇧⌘R")
        #expect(NodeAction.moveToTrash.shortcut?.display == "⌘⌫")
        #expect(NodeAction.quickLook.shortcut?.display == "Leertaste")
        #expect(NodeAction.copyPath.title(count: 3) == "3 Pfade kopieren")
    }

    @Test("Regeln für Zoom, Info, Rescan und Papierkorb")
    func rules() throws {
        let tree = smallTree()
        let lib = try #require(tree.index(ofPath: "Library"))
        let film = try #require(tree.index(ofPath: "Movies/film.mov"))
        let leer = try #require(tree.index(ofPath: "leer"))
        let prot = ProtectedPaths(home: "/Users/demo", appBundlePath: nil, volumeRoots: ["/"])
        let c = ActionContext(tree: tree, focus: 0, protection: prot)
        #expect(NodeAction.zoomIn.availability(targets: [lib], context: c) == .enabled)
        #expect(NodeAction.zoomIn.availability(targets: [film], context: c) == .disabled("Nur für Ordner"))
        #expect(NodeAction.zoomIn.availability(targets: [0], context: c) == .disabled("Ist bereits die Mitte"))
        #expect(NodeAction.zoomIn.availability(targets: [leer], context: c) == .disabled("Ordner ist leer"))
        #expect(NodeAction.info.availability(targets: [lib, film], context: c).isEnabled == false)
        #expect(NodeAction.copyPath.availability(targets: [lib, film], context: c) == .enabled)
        #expect(NodeAction.revealInFinder.availability(targets: [], context: c) == .disabled("Nichts ausgewählt"))

        // Papierkorb: ~/Library geschützt, mit Grund; die Datei nicht.
        let libTrash = NodeAction.moveToTrash.availability(targets: [lib], context: c)
        #expect(!libTrash.isEnabled)
        #expect(libTrash.reason?.contains("~/Library als Ganzes") == true)
        #expect(NodeAction.moveToTrash.availability(targets: [film], context: c) == .enabled)
        #expect(!NodeAction.moveToTrash.availability(targets: [film, lib], context: c).isEnabled)
        #expect(!NodeAction.moveToTrash.availability(targets: [0], context: c).isEnabled)

        // Während eines vollständigen Scans: kein Rescan, kein Papierkorb.
        var scanning = c
        scanning.isFullScanRunning = true
        #expect(!NodeAction.rescan.availability(targets: [lib], context: scanning).isEnabled)
        #expect(!NodeAction.moveToTrash.availability(targets: [film], context: scanning).isEnabled)

        // Rescan: nur Ordner, nicht doppelt, nicht unter einem laufenden Vorfahren.
        #expect(NodeAction.rescan.availability(targets: [lib], context: c) == .enabled)
        #expect(!NodeAction.rescan.availability(targets: [film], context: c).isEnabled)
        var busy = c
        busy.rescanningPaths = ["/Users/demo/Library"]
        #expect(NodeAction.rescan.availability(targets: [lib], context: busy) == .disabled("Wird gerade neu gescannt"))
        let caches = try #require(tree.index(ofPath: "Library/Caches"))
        #expect(NodeAction.rescan.availability(targets: [caches], context: busy).reason?.contains("Library") == true)
        #expect(NodeAction.rescan.availability(targets: [0], context: busy).isEnabled)
    }

    @Test("Einhängepunkte werden ohne crossMountPoints nicht neu eingelesen")
    func mountPoint() throws {
        var b = ScanTreeBuilder(rootName: "r")
        let m = b.directory("Volume", flags: .mountPoint)
        let tree = b.build(rootPath: "/r")
        let prot = ProtectedPaths(home: "/x", appBundlePath: nil, volumeRoots: [])
        #expect(!NodeAction.rescan.availability(targets: [m], context: ActionContext(tree: tree, protection: prot)).isEnabled)
        #expect(NodeAction.rescan.availability(targets: [m], context: ActionContext(tree: tree, protection: prot,
                                                                                  crossMountPoints: true)).isEnabled)
    }
}
