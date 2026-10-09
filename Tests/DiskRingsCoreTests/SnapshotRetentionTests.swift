@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Snapshots: Auswahl, automatisches Speichern und Aufräumen", .timeLimit(.minutes(2)))
struct SnapshotRetentionTests {
    let engine = ScanEngine(options: ScanOptions(workerCount: 2))

    /// Snapshot-Ablage im Fixture-Ordner, nie im echten Application Support.
    func store(_ fx: Fixture, minimumFileSize: UInt64 = 0) -> SnapshotStore {
        SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("ablage")), minimumFileSize: minimumFileSize)
    }

    func info(root: String, uuid: String?, date: Double, name: String? = nil) -> SnapshotInfo {
        let meta = SnapshotMetadata(name: name, date: Date(timeIntervalSince1970: date), rootPath: root, volumeUUID: uuid)
        return SnapshotInfo(url: URL(fileURLWithPath: "/tmp/x-\(date).drsnap"), metadata: meta, fileSize: 1)
    }

    // MARK: Auswahl

    @Test("Passende Snapshots: gleiche Volume-UUID und Scan-Wurzel, neueste zuerst")
    func matching() {
        let all = [
            info(root: "/Users/a", uuid: "V1", date: 100),
            info(root: "/Users/a", uuid: "V1", date: 300),
            info(root: "/Users/a", uuid: "V2", date: 400), // anderes Volume
            info(root: "/Users/b", uuid: "V1", date: 500), // andere Wurzel
            info(root: "/Users/a/x", uuid: "V1", date: 600), // Unterordner zählt nicht
            info(root: "/Users/a", uuid: "V1", date: 200),
        ]
        let c = SnapshotMatching.candidates(all, rootPath: "/Users/a", volumeUUID: "V1")
        #expect(c.map(\.metadata.date.timeIntervalSince1970) == [300, 200, 100])
        #expect(SnapshotMatching.defaultSelection(c)?.metadata.date.timeIntervalSince1970 == 300)
        #expect(SnapshotMatching.defaultSelection([]) == nil)
    }

    @Test("Snapshots des aktuellen Scans (ab dessen Zeitpunkt) werden nicht angeboten")
    func excludesCurrentScan() {
        let all = [
            info(root: "/r", uuid: "V", date: 100),
            info(root: "/r", uuid: "V", date: 200), // automatisch nach dem aktuellen Scan gespeichert
            info(root: "/r", uuid: "V", date: 250),
        ]
        let c = SnapshotMatching.candidates(all, rootPath: "/r", volumeUUID: "V", before: Date(timeIntervalSince1970: 200))
        #expect(c.map(\.metadata.date.timeIntervalSince1970) == [100])
    }

    @Test("Ohne Volume-UUID passen nur Snapshots ohne UUID")
    func nilUUID() {
        let all = [info(root: "/r", uuid: nil, date: 1), info(root: "/r", uuid: "V", date: 2)]
        #expect(SnapshotMatching.candidates(all, rootPath: "/r", volumeUUID: nil).count == 1)
    }

    // MARK: Einstellungen

    @Test("Einstellungen: Standard an und 20, Höchstzahl wird geklemmt")
    func retentionDefaults() {
        let d = SnapshotRetention()
        #expect(d.autoSave)
        #expect(d.maxCount == 20)
        #expect(d.maxCount == SnapshotStore.defaultMaxCount)
        #expect(SnapshotRetention(maxCount: 0).maxCount == SnapshotRetention.maxCountRange.lowerBound)
        #expect(SnapshotRetention(maxCount: 100_000).maxCount == SnapshotRetention.maxCountRange.upperBound)
        var r = SnapshotRetention()
        r.maxCount = -5
        #expect(r.maxCount == 1)
    }

    // MARK: Speichern und Aufräumen (nur im Fixture-Ordner)

    @Test("Automatisch speichern: aus → keine Datei; an → gespeichert und auf die Höchstzahl aufgeräumt")
    func autoSave() throws {
        let fx = try Fixture()
        let root = try fx.dir("baum")
        try fx.file("baum/a.bin", size: 50_000)
        let s = store(fx)
        let result = try engine.scanBlocking(root)

        let off = try s.autoSave(result, retention: SnapshotRetention(autoSave: false), date: Date())
        #expect(off == nil)
        #expect(try s.list().isEmpty)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var lastSaved: SnapshotInfo?
        for i in 0 ..< 5 {
            let out = try #require(try s.autoSave(result, retention: SnapshotRetention(maxCount: 3),
                                                  date: base.addingTimeInterval(Double(i) * 60)))
            lastSaved = out.saved
            #expect(out.pruned.count == (i >= 3 ? 1 : 0))
        }
        let left = try s.list(rootPath: result.tree.rootPath)
        #expect(left.count == 3)
        // Die neuesten bleiben, der eben gespeicherte ist dabei.
        #expect(left.first?.id == lastSaved?.id)
        #expect(left.map(\.metadata.date) == (2 ..< 5).reversed().map { base.addingTimeInterval(Double($0) * 60) })
    }

    @Test("Manuell speichern mit Namen räumt nur dieselbe Scan-Wurzel auf")
    func manualSaveAndPrune() throws {
        let fx = try Fixture()
        let a = try fx.dir("a"), b = try fx.dir("b")
        try fx.file("a/x.bin", size: 10_000)
        try fx.file("b/y.bin", size: 10_000)
        let s = store(fx)
        let ra = try engine.scanBlocking(a), rb = try engine.scanBlocking(b)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try s.save(rb, date: t0)
        try s.save(rb, date: t0.addingTimeInterval(1))
        for i in 0 ..< 3 {
            let meta = SnapshotMetadata.current(for: ra, name: "Stand \(i)", date: t0.addingTimeInterval(Double(10 + i)))
            let out = try s.saveAndPrune(ra.tree, metadata: meta, retention: SnapshotRetention(maxCount: 2))
            #expect(out.saved.metadata.name == "Stand \(i)")
        }
        #expect(try s.list(rootPath: ra.tree.rootPath).map(\.metadata.name) == ["Stand 2", "Stand 1"])
        #expect(try s.list(rootPath: rb.tree.rootPath).count == 2) // andere Wurzel unberührt
    }

    @Test("Leerer oder nur aus Leerzeichen bestehender Name wird zu „ohne Namen“")
    func nameNormalization() {
        #expect(SnapshotNaming.normalized("  ") == nil)
        #expect(SnapshotNaming.normalized("") == nil)
        #expect(SnapshotNaming.normalized(nil) == nil)
        #expect(SnapshotNaming.normalized("  vor Xcode-Update \n") == "vor Xcode-Update")
    }

    @Test("Anzeigename: Name, sonst Datum")
    func displayName() {
        let tz = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_790_926_440)
        let named = SnapshotMetadata(name: "vor Update", date: d, rootPath: "/r")
        let plain = SnapshotMetadata(date: d, rootPath: "/r")
        #expect(SnapshotNaming.title(named, timeZone: tz) == "vor Update")
        #expect(SnapshotNaming.title(plain, timeZone: tz) == "Snapshot vom 02.10.2026, 07:34")
        #expect(SnapshotNaming.longDate(d, timeZone: tz) == "02.10.2026, 07:34")
    }
}
