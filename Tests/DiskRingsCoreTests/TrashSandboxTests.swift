@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Papierkorb in der App-Sandbox: Fehler der Sandbox bekommen eine klare
/// Meldung, und ⌘Z legt nur zurück, wenn der Elternordner freigegeben ist.
/// Alles läuft in temporären Verzeichnissen mit einem eigenen Papierkorb.
@Suite("Papierkorb in der Sandbox", .timeLimit(.minutes(1)), .language("en"))
struct TrashSandboxTests {
    let noProtection = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: [])

    /// Papierkorb, der Verschieben bzw. Zurücklegen mit einem Rechtefehler verweigert.
    final class DenyingTrash: FileTrashing, @unchecked Sendable {
        let inner: TempTrash
        var denyTrash = false
        var denyMove = false
        var deniedPaths: Set<String> = []
        init(_ dir: String) { inner = TempTrash(dir) }

        static let permissionError = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                                                      code: Int(EPERM))])

        func trashItem(at url: URL) throws -> URL? {
            if denyTrash { throw Self.permissionError }
            return try inner.trashItem(at: url)
        }

        func moveItem(at src: URL, to dst: URL) throws {
            if denyMove { throw Self.permissionError }
            try inner.moveItem(at: src, to: dst)
        }

        func itemExists(atPath path: String) -> Bool {
            deniedPaths.contains(path) ? false : inner.itemExists(atPath: path)
        }

        func isAccessDenied(atPath path: String) -> Bool { deniedPaths.contains(path) }
    }

    private func item(_ fx: Fixture, _ rel: String) -> TrashItem {
        TrashItem(node: 1, path: fx.path(rel), name: (rel as NSString).lastPathComponent, isDirectory: false,
                  allocatedSize: 1000, logicalSize: 1000, fileCount: 1)
    }

    @Test("Sandbox verweigert das Verschieben: verständliche Meldung statt Systemtext")
    func trashDenied() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        let trash = DenyingTrash(fx.path("trash"))
        trash.denyTrash = true
        let sandboxed = TrashService(fileManager: trash, protection: noProtection, sandboxed: true)
        let out = sandboxed.trash(TrashPlan(items: [item(fx, "a.bin")]))
        #expect(out.trashed.isEmpty)
        #expect(out.failures.first?.message == L("trash.error.sandboxDenied"))
        #expect(FileManager.default.fileExists(atPath: fx.path("a.bin")))

        // Ohne Sandbox bleibt es beim Text des Systems.
        let plain = TrashService(fileManager: trash, protection: noProtection)
        let out2 = plain.trash(TrashPlan(items: [item(fx, "a.bin")]))
        #expect(out2.failures.first?.message != L("trash.error.sandboxDenied"))
    }

    @Test("⌘Z: Elternordner nicht mehr freigegeben → nichts wird verschoben, Hinweis auf Freigabe bzw. Finder")
    func undoWithoutGrant() throws {
        let fx = try Fixture()
        try fx.file("granted/a.bin", size: 1000)
        let trash = DenyingTrash(fx.path("trash"))
        let parent = fx.path("granted")
        var allowed = true
        let service = TrashService(fileManager: trash, protection: noProtection, sandboxed: true,
                                   accessCheck: { path in allowed && path.hasPrefix(parent) })
        let record = try #require(service.trash(TrashPlan(items: [item(fx, "granted/a.bin")])).trashed.first)
        allowed = false
        let r = service.restore([record])
        #expect(r.restored.isEmpty)
        #expect(r.failures.first?.message == L("trash.undo.noAccess"))
        #expect(FileManager.default.fileExists(atPath: try #require(record.trashURL).path))
        #expect(!FileManager.default.fileExists(atPath: fx.path("granted/a.bin")))

        allowed = true
        let r2 = service.restore([record])
        #expect(r2.restored == [fx.path("granted/a.bin")])
    }

    @Test("⌘Z: Sandbox verweigert das Zurücklegen → Hinweis auf „Zurücklegen“ im Finder")
    func undoMoveDenied() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        let trash = DenyingTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection, sandboxed: true,
                                   accessCheck: { _ in true })
        let record = try #require(service.trash(TrashPlan(items: [item(fx, "a.bin")])).trashed.first)
        trash.denyMove = true
        let r = service.restore([record])
        #expect(r.restored.isEmpty)
        #expect(r.failures.first?.message == L("trash.undo.sandboxDenied"))
    }

    @Test("⌘Z: Papierkorb für die Sandbox nicht lesbar → nicht „nicht mehr im Papierkorb“, sondern Finder-Hinweis")
    func undoTrashUnreadable() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1000)
        let trash = DenyingTrash(fx.path("trash"))
        let service = TrashService(fileManager: trash, protection: noProtection, sandboxed: true,
                                   accessCheck: { _ in true })
        let record = try #require(service.trash(TrashPlan(items: [item(fx, "a.bin")])).trashed.first)
        trash.deniedPaths = [try #require(record.trashURL).path]
        #expect(service.restore([record]).failures.first?.message == L("trash.undo.sandboxDenied"))

        // Ohne Sandbox bleibt die bisherige Meldung.
        let plain = TrashService(fileManager: trash, protection: noProtection)
        #expect(plain.restore([record]).failures.first?.message == L("trash.undo.notInTrash"))
    }

    @Test("Rechtefehler werden erkannt (Cocoa, POSIX, darunterliegend)")
    func permissionErrors() {
        #expect(TrashService.isPermissionError(DenyingTrash.permissionError))
        #expect(TrashService.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        #expect(TrashService.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(TrashService.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!TrashService.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    @Test("Ohne Sandbox meldet isAccessDenied für einen fehlenden Pfad nichts")
    func accessDeniedDefault() {
        #expect(!FileManager.default.isAccessDenied(atPath: "/nonexistent-\(UUID().uuidString)"))
    }
}
