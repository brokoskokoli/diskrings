@testable import DiskRingsCore
import Foundation
import Testing

/// Abnahme-Befunde zu den Snapshot-Dateien: beschädigte bzw. abgeschnittene
/// Dateien erkennen und aufräumen; Umbenennen schreibt nur den Kopf neu.
@Suite("Snapshots: beschädigte Dateien, Umbenennen ohne Dekodieren", .timeLimit(.minutes(1)))
struct SnapshotDamageTests {
    func scan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("daten/a.bin", size: 1_500_000)
        try fx.file("daten/b.bin", size: 1_200_000)
        try fx.file("daten/klein.txt", size: 100)
        return try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("daten"))
    }

    func store(_ fx: Fixture) -> SnapshotStore {
        SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("snapshots")))
    }

    /// Schneidet die Datei auf `keep` Byte ab.
    func truncate(_ url: URL, keep: Int) throws {
        let data = try Data(contentsOf: url)
        try data.prefix(keep).write(to: url)
    }

    @Test("Abgeschnittene Datei (Kopf lesbar) gilt als beschädigt und erscheint nicht in der normalen Liste")
    func truncatedIsDamaged() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let good = try s.save(r, name: "gut", date: Date(timeIntervalSince1970: 1_790_000_000))
        let bad = try s.save(r, name: "kaputt", date: Date(timeIntervalSince1970: 1_790_003_600))
        try truncate(bad.url, keep: Int(bad.fileSize) - 10)

        #expect(try s.list().map(\.url) == [good.url])
        let damaged = try s.listDamaged()
        #expect(damaged.map(\.url) == [bad.url])
        #expect(damaged.first?.metadata?.name == "kaputt")
        #expect(damaged.first?.reason.isEmpty == false)
        #expect(damaged.first?.fileSize == bad.fileSize - 10)
    }

    @Test("Datei ohne lesbaren Kopf (Müll, zu kurz) gilt als beschädigt")
    func garbageIsDamaged() throws {
        let fx = try Fixture()
        let s = store(fx)
        let dir = try fx.dir("snapshots/unbekannt")
        try Data("kein snapshot".utf8).write(to: URL(fileURLWithPath: dir + "/muell.drsnap"))
        try Data([0x44, 0x52]).write(to: URL(fileURLWithPath: dir + "/kurz.drsnap"))
        // Andere Dateien in der Ablage werden ignoriert.
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/notiz.txt"))
        let damaged = try s.listDamaged()
        #expect(Set(damaged.map(\.url.lastPathComponent)) == ["muell.drsnap", "kurz.drsnap"])
        #expect(damaged.allSatisfy { $0.metadata == nil })
        #expect(try s.list().isEmpty)
    }

    @Test("Beschädigte Datei lässt sich löschen (nur innerhalb der Ablage)")
    func deleteDamaged() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let bad = try s.save(r)
        try truncate(bad.url, keep: 40)
        let d = try #require(try s.listDamaged().first)
        try s.delete(d)
        #expect(!FileManager.default.fileExists(atPath: bad.url.path))
        let outside = DamagedSnapshot(url: URL(fileURLWithPath: fx.path("daten/a.bin")), fileSize: 0, reason: "x",
                                      metadata: nil)
        #expect(throws: SnapshotError.self) { try s.delete(outside) }
        #expect(FileManager.default.fileExists(atPath: fx.path("daten/a.bin")))
    }

    @Test("prune räumt beschädigte Dateien der Scan-Wurzel und solche ohne lesbaren Kopf auf")
    func pruneRemovesDamaged() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let uuid = VolumeInfo.forPath(fx.root)?.uuid
        let good = try s.save(r, name: "gut", date: Date(timeIntervalSince1970: 1_790_000_000))
        let bad = try s.save(r, name: "kaputt", date: Date(timeIntervalSince1970: 1_790_003_600))
        try truncate(bad.url, keep: Int(bad.fileSize) - 10)
        let garbage = good.url.deletingLastPathComponent().appendingPathComponent("muell.drsnap")
        try Data("kein snapshot".utf8).write(to: garbage)
        // Beschädigter Snapshot einer anderen Scan-Wurzel bleibt für deren prune.
        try fx.file("anders/x.bin", size: 1_100_000)
        let other = try s.save(try ScanEngine().scanBlocking(fx.path("anders")))
        try truncate(other.url, keep: Int(other.fileSize) - 10)

        _ = try s.prune(maxCount: 20, rootPath: fx.path("daten"), volumeUUID: uuid)
        #expect(!FileManager.default.fileExists(atPath: bad.url.path))
        #expect(!FileManager.default.fileExists(atPath: garbage.path))
        #expect(FileManager.default.fileExists(atPath: good.url.path))
        #expect(FileManager.default.fileExists(atPath: other.url.path))
        #expect(try s.list().map(\.url) == [good.url])
    }

    @Test("Umbenennen schreibt nur den Kopf neu: Nutzdaten bleiben Byte für Byte gleich, ohne sie zu dekodieren")
    func renameRewritesHeaderOnly() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let info = try s.save(r, name: "alt")
        let before = try Data(contentsOf: info.url)
        // Letztes Nutzdaten-Byte verfälschen: Dekodieren schlägt jetzt fehl
        // (Prüfsumme), Umbenennen muss trotzdem gehen und darf nichts ändern.
        var corrupted = before
        corrupted[corrupted.count - 1] ^= 0xFF
        try corrupted.write(to: info.url)
        #expect(throws: SnapshotError.self) { try s.load(info) }

        let renamed = try s.rename(info, to: "ein deutlich längerer neuer Name – mit Ümlauten")
        #expect(renamed.metadata.name == "ein deutlich längerer neuer Name – mit Ümlauten")
        #expect(try SnapshotFile.readMetadata(info.url).name == renamed.metadata.name)
        #expect(try SnapshotFile.readMetadata(info.url).id == info.metadata.id)
        let after = try Data(contentsOf: info.url)
        #expect(renamed.fileSize == UInt64(after.count))
        let oldHeader = try SnapshotFile.headerRange(of: corrupted)
        let newHeader = try SnapshotFile.headerRange(of: after)
        #expect(after[newHeader.upperBound...] == corrupted[oldHeader.upperBound...])
    }

    @Test("Umbenennen: intakter Snapshot bleibt ladbar und identisch; Name entfernen geht auch")
    func renameRoundtrip() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let info = try s.save(r, name: "alt")
        let original = try s.load(info)
        let renamed = try s.rename(info, to: nil)
        #expect(renamed.metadata.name == nil)
        let loaded = try s.load(renamed)
        #expect(loaded.metadata.name == nil)
        #expect(loaded.tree.isIdentical(to: original.tree))
        var expected = original.metadata
        expected.name = nil
        #expect(loaded.metadata == expected)
    }

    @Test("Umbenennen einer abgeschnittenen Datei schlägt fehl und lässt sie unverändert")
    func renameTruncatedFails() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let info = try s.save(r, name: "alt")
        try truncate(info.url, keep: Int(info.fileSize) - 5)
        let before = try Data(contentsOf: info.url)
        #expect(throws: SnapshotError.self) { try s.rename(info, to: "neu") }
        #expect(try Data(contentsOf: info.url) == before)
    }

    @Test("Speichern legt keine halb geschriebenen .drsnap-Dateien an (temporäre Datei, dann Umbenennen)")
    func saveLeavesNoTemporaryFiles() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s = store(fx)
        let info = try s.save(r)
        let files = try FileManager.default.contentsOfDirectory(atPath: info.url.deletingLastPathComponent().path)
        #expect(files == [info.url.lastPathComponent])
        #expect(try s.listDamaged().isEmpty)
    }
}
