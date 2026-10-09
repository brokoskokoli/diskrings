@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Nachprüfung: Snapshots einer neueren Formatversion nie automatisch löschen,
/// verwaiste temporäre Dateien aufräumen.
@Suite("Nachprüfung: neuere Formatversion, temporäre Dateien", .timeLimit(.minutes(2)))
struct SnapshotVersionTests {
    let fm = FileManager.default

    func scan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("daten/a.bin", size: 1_500_000)
        return try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("daten"))
    }

    // MARK: 1. Neuere Formatversion, Temp-Dateien

    @Test("Snapshot einer neueren Formatversion: als „neuere Version“ gelistet, prune löscht ihn nie, manuell geht es")
    func newerVersionNotPruned() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("snapshots")))
        let vol = VolumeInfo.forPath(fx.root)
        let info = try s.save(r, volume: vol)
        var data = try Data(contentsOf: info.url)
        data[8] = 2 // Formatversion 2
        try data.write(to: info.url)

        let listed = try #require(try s.listDamaged().first)
        #expect(listed.kind == .newerVersion)
        #expect(listed.statusLabel == "neuere Version")
        #expect(try s.list().isEmpty)
        _ = try s.prune(maxCount: 20, rootPath: r.tree.rootPath, volumeUUID: vol?.uuid)
        _ = try s.prune(maxCount: 0, rootPath: r.tree.rootPath)
        #expect(fm.fileExists(atPath: info.url.path))
        // Echte Beschädigung bleibt „beschädigt“.
        let bad = try s.save(r, volume: vol, date: Date(timeIntervalSince1970: 1_790_000_000))
        try Data(try Data(contentsOf: bad.url).prefix(30)).write(to: bad.url)
        #expect(try s.listDamaged().first { $0.url == bad.url }?.kind == .damaged)
        #expect(try s.listDamaged().first { $0.url == bad.url }?.statusLabel == "beschädigt")
        // Manuell löschen geht.
        try s.delete(listed)
        #expect(!fm.fileExists(atPath: info.url.path))
    }

    @Test("prune räumt verwaiste temporäre Dateien (.<uuid>.tmp) älter als 1 h auf, jüngere und fremde nicht")
    func pruneRemovesOldTempFiles() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("snapshots")))
        let info = try s.save(r)
        let dir = info.url.deletingLastPathComponent()
        let old = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        let young = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        let foreign = dir.appendingPathComponent(".nicht-von-uns.tmp")
        for u in [old, young, foreign] { try Data("x".utf8).write(to: u) }
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: foreign.path)

        _ = try s.prune(maxCount: 20, rootPath: r.tree.rootPath)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: young.path))
        #expect(fm.fileExists(atPath: foreign.path))
        #expect(fm.fileExists(atPath: info.url.path))
    }
}
