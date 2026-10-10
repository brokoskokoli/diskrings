@testable import DiskRingsCore
import Foundation
import Testing

/// Review-Befunde zum Papierkorb-Plan: Einhängepunkte sind nie löschbar,
/// und „Nicht mehr fragen“ greift nicht, wenn die Größe unsicher ist
/// (nur in der Cloud, nicht lesbar, Einhängepunkt, unvollständiger Baum).
@Suite("Papierkorb: Einhängepunkte und unsichere Größen", .timeLimit(.minutes(1)), .language("de"))
struct TrashPlanSafetyTests {
    let noProtection = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: [])

    /// /r mit klein.bin, cloud/ (dataless), gesperrt/ (unreadable), tief/x/y/z.bin (z dataless),
    /// ordner/ mit eingehängtem Volume vol/ (mountPoint) und normal/.
    func tree(complete: Bool = true) -> ScanTree {
        var b = ScanTreeBuilder(rootName: "r")
        b.file("klein.bin", size: 1000)
        b.directory("cloud", flags: .dataless)
        b.directory("gesperrt", flags: .unreadable)
        let tief = b.directory("tief")
        let x = b.directory("x", in: tief)
        let y = b.directory("y", in: x)
        b.file("z.bin", size: 0, in: y, flags: .dataless)
        let ordner = b.directory("ordner")
        b.directory("vol", in: ordner, flags: .mountPoint)
        b.file("a.bin", size: 10, in: ordner)
        let normal = b.directory("normal")
        b.file("n.bin", size: 500, in: normal)
        if !complete { b.partialDirectory("teil", ownSize: 100, files: 3) }
        return b.build(rootPath: "/r")
    }

    func node(_ t: ScanTree, _ p: String) throws -> Int32 { try #require(t.index(ofPath: p)) }

    @Test("Einhängepunkt selbst → abgelehnt, mit klarer Meldung")
    func mountPointRejected() throws {
        let t = tree()
        let vol = try node(t, "ordner/vol")
        let r = TrashPlan.make(targets: [vol], in: t, protection: noProtection)
        #expect(r == .failure(.mountPoint(path: "/r/ordner/vol")))
        if case .failure(let e) = r { #expect(e.message.contains("Einhängepunkt") && e.message.contains("vol")) }
        let a = ActionContext(tree: t, protection: noProtection)
        #expect(!NodeAction.moveToTrash.availability(targets: [vol], context: a).isEnabled)
    }

    @Test("Ordner, der einen Einhängepunkt enthält → abgelehnt")
    func containsMountPointRejected() throws {
        let t = tree()
        let ordner = try node(t, "ordner")
        let r = TrashPlan.make(targets: [ordner], in: t, protection: noProtection)
        #expect(r == .failure(.containsMountPoint(path: "/r/ordner", mountPoint: "/r/ordner/vol")))
        // Geschwister ohne Einhängepunkt bleiben erlaubt.
        #expect((try? TrashPlan.make(targets: [try node(t, "ordner/a.bin")], in: t, protection: noProtection).get()) != nil)
    }

    @Test("Nur in der Cloud, nicht lesbar, auch tief im Teilbaum → Größe unsicher, immer fragen")
    func uncertainAlwaysAsks() throws {
        let t = tree()
        for p in ["cloud", "gesperrt", "tief", "tief/x/y/z.bin"] {
            let plan = try TrashPlan.make(targets: [try node(t, p)], in: t, protection: noProtection).get()
            #expect(plan.hasUncertainSize, "\(p)")
            #expect(!plan.allowsDontAskAgain, "\(p)")
            #expect(TrashConfirmation.needsConfirmation(plan, dontAskAgain: true), "\(p)")
            #expect(plan.alwaysAskReason == L("trash.confirm.sizeUncertain"))
        }
        // Zusammen mit einem sicheren Element: die ganze Auswahl wird bestätigt.
        let mixed = try TrashPlan.make(targets: [try node(t, "klein.bin"), try node(t, "cloud")], in: t,
                                       protection: noProtection).get()
        #expect(TrashConfirmation.needsConfirmation(mixed, dontAskAgain: true))
    }

    @Test("Sichere kleine Elemente: „Nicht mehr fragen“ wirkt weiter")
    func certainSmall() throws {
        let t = tree()
        for p in ["klein.bin", "normal", "normal/n.bin"] {
            let plan = try TrashPlan.make(targets: [try node(t, p)], in: t, protection: noProtection).get()
            #expect(!plan.hasUncertainSize, "\(p)")
            #expect(!TrashConfirmation.needsConfirmation(plan, dontAskAgain: true), "\(p)")
        }
        let plan = try TrashPlan.make(targets: [try node(t, "klein.bin")], in: t, protection: noProtection).get()
        #expect(plan.alwaysAskReason == L("trash.confirm.alwaysAsk"))
    }

    @Test("Unvollständiger Baum oder laufender Teil-Rescan im Teilbaum → Größe unsicher")
    func incomplete() throws {
        let t = tree(complete: false)
        #expect(!t.isComplete)
        let p1 = try TrashPlan.make(targets: [try node(t, "klein.bin")], in: t, protection: noProtection).get()
        #expect(p1.hasUncertainSize)
        let full = tree()
        let normal = try node(full, "normal")
        // Rescan läuft im Ordner selbst, darunter oder darüber.
        for running in ["/r/normal", "/r/normal/sub", "/r"] {
            let p = try TrashPlan.make(targets: [normal], in: full, protection: noProtection,
                                       incompletePaths: [running]).get()
            #expect(p.hasUncertainSize, "\(running)")
        }
        let other = try TrashPlan.make(targets: [normal], in: full, protection: noProtection,
                                       incompletePaths: ["/r/normalisiert", "/r/tief"]).get()
        #expect(!other.hasUncertainSize)
    }

    @Test("Art auf der Platte geändert (Datei ist jetzt Ordner) → immer fragen")
    func kindChangedOnDisk() throws {
        let fx = try Fixture()
        try fx.file("scan/ding", size: 100)
        try fx.file("scan/bleibt", size: 100)
        let t = try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("scan")).tree
        let plan = try TrashPlan.make(targets: [try node(t, "ding"), try node(t, "bleibt")], in: t,
                                      protection: noProtection).get()
        #expect(!plan.checkingCurrentKinds(using: FileManager.default).hasUncertainSize)
        try FileManager.default.removeItem(atPath: fx.path("scan/ding"))
        try fx.file("scan/ding/innen.bin", size: 5_000_000)
        let checked = plan.checkingCurrentKinds(using: FileManager.default)
        #expect(checked.items.map(\.sizeIsUncertain) == [true, false])
        #expect(TrashConfirmation.needsConfirmation(checked, dontAskAgain: true))
    }

    @Test("Schutzliste: Volume-Wurzeln lassen sich zur Laufzeit auffrischen")
    func refreshVolumes() {
        let p = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: ["/"])
        #expect(!p.isProtected("/Volumes/Neu"))
        let q = p.refreshingVolumeRoots(["/", "/Volumes/Neu"])
        #expect(q.reason(for: "/Volumes/Neu") == .volumeRoot)
        #expect(q.home == p.home)
        // Standard: die aktuell eingehängten Volumes (enthält immer „/“).
        #expect(p.refreshingVolumeRoots().volumeRoots.contains("/"))
    }

    @Test("Dienst: echter Einhängepunkt (Disk-Image) wird nicht verschoben",
          .enabled(if: DiskImage.isAvailable, "hdiutil nicht verfügbar"))
    func serviceRefusesRealMountPoint() throws {
        let fx = try Fixture()
        let img = try DiskImage(fs: "HFS+", in: fx.root)
        defer { img.detach() }
        try Data("x".utf8).write(to: URL(fileURLWithPath: img.mountPoint + "/datei.txt"))
        let trash = TempTrash(fx.path("trash"))
        let plan = TrashPlan(items: [TrashItem(node: 1, path: img.mountPoint, name: "mnt", isDirectory: true,
                                               allocatedSize: 1, logicalSize: 1, fileCount: 1)])
        let out = TrashService(fileManager: trash, protection: noProtection).trash(plan)
        #expect(out.trashed.isEmpty)
        #expect(out.failures.count == 1)
        #expect(trash.trashCalls.isEmpty)
        #expect(trash.isMountPoint(atPath: img.mountPoint))
        #expect(!trash.isMountPoint(atPath: fx.path("trash")))
        #expect(FileManager.default.fileExists(atPath: img.mountPoint + "/datei.txt"))
    }
}
