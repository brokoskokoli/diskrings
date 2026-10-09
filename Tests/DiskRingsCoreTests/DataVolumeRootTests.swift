@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Nachprüfung: Scan-Wurzel genau /System/Volumes/Data.
@Suite("Nachprüfung: Scan-Wurzel /System/Volumes/Data", .timeLimit(.minutes(2)))
struct DataVolumeRootTests {
    let fm = FileManager.default

    func scan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("daten/a.bin", size: 1_500_000)
        return try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("daten"))
    }

    // MARK: 2. Scan-Wurzel /System/Volumes/Data

    @Test("normalize bildet genau /System/Volumes/Data auf / ab")
    func normalizeDataVolume() {
        #expect(ProtectedPaths.normalize("/System/Volumes/Data") == "/")
        #expect(ProtectedPaths.normalize("/System/Volumes/Data/") == "/")
        #expect(ProtectedPaths.normalize("/system/volumes/data") == "/")
        #expect(ProtectedPaths.normalize("/System/Volumes/Data/Users/x") == "/users/x")
        #expect(ProtectedPaths.normalize("/System/Volumes/DataX") == "/system/volumes/datax")
        // Die Wurzel selbst bleibt geschützt.
        let p = ProtectedPaths(home: "/Users/x", appBundlePath: nil, volumeRoots: [])
        #expect(p.reason(for: "/System/Volumes/Data") == .volumeRoot)
    }

    @Test("Scan-Wurzel /System/Volumes/Data: legitimer Pfad besteht die Prüfung vor dem Papierkorb")
    func dataVolumeRootCheck() throws {
        let fx = try Fixture()
        try fx.file("sub/a.bin", size: 10)
        let root = "/System/Volumes/Data"
        let path = root + fx.path("sub/a.bin")
        guard fm.fileExists(atPath: path) else { return } // kein Data-Volume (sehr altes System)
        let service = TrashService(fileManager: TempTrash(fx.path("trash")),
                                   protection: ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: []))
        #expect(service.checkResolved(path, rootPath: root) == nil)
        // Symlink im Pfad wird weiterhin erkannt.
        try fx.file("draussen/a.bin", size: 10)
        try fm.removeItem(atPath: fx.path("sub"))
        try fm.createSymbolicLink(atPath: fx.path("sub"), withDestinationPath: fx.path("draussen"))
        #expect(service.checkResolved(path, rootPath: root) != nil)
    }
}
