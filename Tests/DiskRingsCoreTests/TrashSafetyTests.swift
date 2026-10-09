@testable import DiskRingsCore
import Foundation
import Testing

/// Abnahme-Befunde zum Papierkorb: Undo darf nur genau das Objekt
/// zurücklegen, das verschoben wurde, und vor dem Verschieben wird der
/// aufgelöste Pfad erneut geprüft. Alles läuft in temporären Verzeichnissen.
@Suite("Papierkorb: Identität beim Undo, aufgelöste Pfade", .timeLimit(.minutes(1)))
struct TrashSafetyTests {
    let noProtection = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: [])
    let fm = FileManager.default

    private func item(_ fx: Fixture, _ rel: String, directory: Bool = false) -> TrashItem {
        TrashItem(node: 1, path: fx.path(rel), name: (rel as NSString).lastPathComponent, isDirectory: directory,
                  allocatedSize: 1000, logicalSize: 1000, fileCount: 1)
    }

    @Test("Undo: Papierkorb geleert, fremde Datei unter derselben Adresse → wird nicht zurückgelegt")
    func undoRefusesForeignFile() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        let trash = TempTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection)
        let record = try #require(service.trash(TrashPlan(items: [item(fx, "a.bin")])).trashed.first)
        let url = try #require(record.trashURL)
        // Papierkorb leeren; danach landet eine andere Datei gleichen Namens dort.
        try fm.removeItem(at: url)
        try fx.file("trash/a.bin", size: 1000, byte: 0x62)

        let r = service.restore([record])
        #expect(r.restored.isEmpty)
        #expect(r.failures.count == 1)
        #expect(r.failures.first?.message.contains("anderes Objekt") == true)
        // Die fremde Datei bleibt im Papierkorb, am alten Ort liegt nichts.
        #expect(fm.fileExists(atPath: url.path))
        #expect(!fm.fileExists(atPath: fx.path("a.bin")))
    }

    @Test("Undo: fremder Ordner unter derselben Adresse → wird nicht zurückgelegt")
    func undoRefusesForeignDirectory() throws {
        let fx = try Fixture()
        try fx.file("ordner/x.bin", size: 1000)
        let trash = TempTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection)
        let record = try #require(service.trash(TrashPlan(items: [item(fx, "ordner", directory: true)])).trashed.first)
        let url = try #require(record.trashURL)
        try fm.removeItem(at: url)
        try fx.file("trash/ordner/x.bin", size: 1000)

        let r = service.restore([record])
        #expect(r.restored.isEmpty && r.failures.count == 1)
        #expect(!fm.fileExists(atPath: fx.path("ordner")))
        #expect(fm.fileExists(atPath: fx.path("trash/ordner/x.bin")))
    }

    @Test("Undo: Datei im Papierkorb verändert → wird nicht zurückgelegt; unverändert → klappt")
    func undoChecksModification() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        try fx.file("b.bin", size: 1000)
        let trash = TempTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection)
        let out = service.trash(TrashPlan(items: [item(fx, "a.bin"), item(fx, "b.bin")]))
        #expect(out.trashed.count == 2)
        #expect(out.trashed.allSatisfy { $0.identity != nil })
        // a.bin im Papierkorb vergrößern (gleiche Inode, andere Größe).
        let aURL = try #require(out.trashed[0].trashURL)
        let h = try FileHandle(forWritingTo: aURL)
        try h.seekToEnd()
        try h.write(contentsOf: Data(repeating: 1, count: 10))
        try h.close()

        let r = service.restore(out.trashed)
        #expect(r.restored == [fx.path("b.bin")])
        #expect(r.failures.map(\.path) == [fx.path("a.bin")])
        #expect(fm.fileExists(atPath: fx.path("b.bin")))
        #expect(!fm.fileExists(atPath: fx.path("a.bin")))
    }

    @Test("Undo ohne bekannte Identität wird verweigert")
    func undoWithoutIdentity() throws {
        let fx = try Fixture()
        try fx.file("trash/a.bin", size: 10)
        let service = TrashService(fileManager: TempTrash(fx.path("trash")), protection: noProtection)
        let r = service.restore([TrashRecord(originalPath: fx.path("a.bin"), trashURL: URL(fileURLWithPath: fx.path("trash/a.bin")),
                                             name: "a.bin", allocatedSize: 10)])
        #expect(r.restored.isEmpty && r.failures.count == 1)
        #expect(!fm.fileExists(atPath: fx.path("a.bin")))
    }

    @Test("Elternordner durch Symlink nach außerhalb ersetzt → nichts wird verschoben")
    func symlinkedParentOutsideRoot() throws {
        let fx = try Fixture()
        try fx.file("scan/sub/wichtig.bin", size: 1000)
        try fx.file("draussen/wichtig.bin", size: 2000)
        let tree = try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("scan")).tree
        let n = try #require(tree.index(ofPath: "sub/wichtig.bin"))
        let plan = try TrashPlan.make(targets: [n], in: tree, protection: noProtection).get()
        try fm.removeItem(atPath: fx.path("scan/sub"))
        try fm.createSymbolicLink(atPath: fx.path("scan/sub"), withDestinationPath: fx.path("draussen"))

        let trash = TempTrash(fx.path("trash"))
        let out = TrashService(fileManager: trash, protection: noProtection).trash(plan)
        #expect(out.trashed.isEmpty)
        #expect(out.failures.count == 1)
        #expect(out.failures.first?.message.contains("Scan-Wurzel") == true)
        #expect(trash.trashCalls.isEmpty)
        #expect(fm.fileExists(atPath: fx.path("draussen/wichtig.bin")))
    }

    @Test("Elternordner durch Symlink ersetzt, Ziel geschützt → Schutzliste greift auf den aufgelösten Pfad")
    func symlinkedParentProtected() throws {
        let fx = try Fixture()
        try fx.file("scan/a/home/x.bin", size: 1000)
        try fx.file("scan/home/y.bin", size: 1000)
        let prot = ProtectedPaths(home: fx.path("scan/home"), appBundlePath: nil, volumeRoots: [])
        let tree = try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("scan")).tree
        let n = try #require(tree.index(ofPath: "a/home"))
        let plan = try TrashPlan.make(targets: [n], in: tree, protection: prot).get()
        // scan/a → scan: scan/a/home zeigt jetzt auf das (geschützte) Home.
        try fm.removeItem(atPath: fx.path("scan/a"))
        try fm.createSymbolicLink(atPath: fx.path("scan/a"), withDestinationPath: fx.path("scan"))

        let trash = TempTrash(fx.path("trash"))
        let out = TrashService(fileManager: trash, protection: prot).trash(plan)
        #expect(out.trashed.isEmpty)
        #expect(out.failures.first?.message.hasPrefix("Geschützt") == true)
        #expect(trash.trashCalls.isEmpty)
        #expect(fm.fileExists(atPath: fx.path("scan/home/y.bin")))
    }

    @Test("Ohne Symlinks: Scan-Wurzel mit Symlink im eigenen Pfad (/tmp → /private/tmp) bleibt erlaubt")
    func rootThroughSymlinkStillWorks() throws {
        let fx = try Fixture()
        try fx.file("real/scan/d.bin", size: 1000)
        try fm.createSymbolicLink(atPath: fx.path("link"), withDestinationPath: fx.path("real"))
        let tree = try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("link/scan")).tree
        let n = try #require(tree.index(ofPath: "d.bin"))
        let plan = try TrashPlan.make(targets: [n], in: tree, protection: noProtection).get()
        let trash = TempTrash(fx.path("trash"))
        let out = TrashService(fileManager: trash, protection: noProtection).trash(plan)
        #expect(out.failures.isEmpty)
        #expect(out.trashed.count == 1)
        #expect(!fm.fileExists(atPath: fx.path("real/scan/d.bin")))
    }
}
