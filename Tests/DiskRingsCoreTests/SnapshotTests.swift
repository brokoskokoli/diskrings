@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Snapshots: Format und Ablage", .timeLimit(.minutes(2)))
struct SnapshotTests {
    /// Fixture mit großen und kleinen Dateien.
    func sampleScan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("gross/a.bin", size: 3_000_000)
        try fx.file("gross/klein.txt", size: 2000)
        try fx.file("gross/tief/b.bin", size: 1_500_000)
        try fx.file("gross/tief/winzig", size: 10)
        try fx.file("rest/c.bin", size: 1_200_000)
        try fx.file("rest/d.txt", size: 999_000)
        try fx.dir("leer")
        try fx.file("Grüße/ü.bin", size: 1_100_000)
        return try ScanEngine(options: ScanOptions(workerCount: 2)).scanBlocking(fx.root)
    }

    func store(_ fx: Fixture, min: UInt64 = SnapshotStore.defaultMinimumFileSize) -> SnapshotStore {
        SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("snapshots")), minimumFileSize: min)
    }

    @Test("Roundtrip ohne Mindestgröße ergibt einen identischen Baum")
    func roundtripIdentical() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        let s = store(fx, min: 0)
        let info = try s.save(r, name: "vorher")
        let loaded = try s.load(info)
        #expect(loaded.tree.isIdentical(to: r.tree))
        #expect(loaded.tree.isComplete)
        expectValidTree(loaded.tree)
        #expect(loaded.metadata == info.metadata)
        #expect(loaded.metadata.name == "vorher")
        #expect(loaded.metadata.rootPath == fx.root)
        #expect(loaded.metadata.nodeCount == r.tree.count)
        #expect(loaded.metadata.volumeUUID == VolumeInfo.forPath(fx.root)?.uuid)
        #expect(loaded.metadata.volume?.total ?? 0 > 0)
        #expect(loaded.metadata.volume?.unassigned == nil) // keine Volume-Wurzel
        #expect(loaded.metadata.options == SnapshotScanOptions(r.options))
        #expect(info.url.path.hasPrefix(fx.path("snapshots") + "/"))
        #expect(info.url.pathExtension == "drsnap")
    }

    @Test("Roundtrip mit 1 MB Mindestgröße: kleine Dateien nur in der Ordnersumme")
    func roundtripCondensed() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        let s = store(fx)
        let loaded = try s.load(try s.save(r))
        let t = loaded.tree
        expectValidTree(t)
        #expect(!t.isComplete)
        #expect(loaded.metadata.minimumFileSize == 1_000_000)
        // Gleiche Summen an allen Ordnern, gleiche Reihenfolge, kleine Dateien fehlen.
        var checked = 0
        for i in 0 ..< Int32(r.tree.count) {
            let n = r.tree.node(i)
            let p = r.tree.path(of: i)
            if !n.isDirectory, n.allocatedSize < 1_000_000 {
                #expect(t.index(ofPath: p) == nil, "\(p)")
                continue
            }
            let j = try #require(t.index(ofPath: p), "\(p)")
            #expect(t.node(j).allocatedSize == n.allocatedSize)
            #expect(t.node(j).logicalSize == n.logicalSize)
            #expect(t.node(j).fileCount == n.fileCount)
            #expect(t.node(j).flags == n.flags)
            checked += 1
        }
        #expect(checked == 10) // Wurzel, 4 Ordner + tief, 4 große Dateien
        #expect(t.root.child(named: "gross")?.children.map(\.name) == ["a.bin", "tief"])
        #expect(t.root.child(named: "rest")?.childCount == 1) // d.txt (999 kB) fehlt
    }

    @Test("Beschädigte, abgeschnittene und fremde Dateien ergeben saubere Fehler")
    func corruptFiles() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        let data = try SnapshotFile.encode(Snapshot(metadata: .current(for: r), tree: r.tree))
        #expect(try SnapshotFile.decode(data).tree.isIdentical(to: r.tree))

        // Jede Abschneide-Position liefert einen Fehler, nie einen Absturz.
        for cut in stride(from: 0, to: data.count, by: max(1, data.count / 97)) {
            #expect(throws: SnapshotError.self) { try SnapshotFile.decode(data.prefix(cut)) }
        }
        #expect(throws: SnapshotError.truncated) { try SnapshotFile.decode(data.prefix(data.count - 1)) }
        // Einzelne Bytes in den Nutzdaten kippen → Prüfsumme.
        var flipped = data
        flipped[data.count - 10] ^= 0xFF
        #expect(throws: SnapshotError.corrupted("Prüfsumme")) { try SnapshotFile.decode(flipped) }
        // Kopf kaputt
        var badHeader = data
        badHeader[20] = UInt8(ascii: "#")
        #expect(throws: SnapshotError.self) { try SnapshotFile.decode(badHeader) }
        // Fremde Datei
        #expect(throws: SnapshotError.notASnapshot) { try SnapshotFile.decode(Data("Hallo Welt, kein Snapshot".utf8)) }
        // Über den Store: Datei auf der Platte beschädigt
        let s = store(fx, min: 0)
        let info = try s.save(r)
        try data.prefix(data.count / 2).write(to: info.url)
        #expect(throws: SnapshotError.truncated) { try s.load(info) }
    }

    @Test("Strukturprüfung: Nutzdaten mit gültiger Prüfsumme, aber kaputtem Baum")
    func structurallyBroken() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        var payload = SnapshotFile.encodePayload(r.tree)
        // Elternzeiger des zweiten Knotens auf sich selbst setzen.
        payload.withUnsafeMutableBytes { $0.storeBytes(of: Int32(1).littleEndian, toByteOffset: 12 + 40 + 16, as: Int32.self) }
        #expect(throws: SnapshotError.self) { try SnapshotFile.decodePayload(payload, rootPath: "/x") }
        // Summe verletzt
        var p2 = SnapshotFile.encodePayload(r.tree)
        p2.withUnsafeMutableBytes { $0.storeBytes(of: UInt64(1).littleEndian, toByteOffset: 12, as: UInt64.self) }
        #expect(throws: SnapshotError.self) { try SnapshotFile.decodePayload(p2, rootPath: "/x") }
    }

    @Test("Versionsprüfung: neuere Formatversion wird abgelehnt")
    func versionCheck() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        var data = try SnapshotFile.encode(Snapshot(metadata: .current(for: r), tree: r.tree))
        data[8] = 2 // Formatversion (UInt16 LE) direkt nach der Kennung
        data[9] = 0
        #expect(throws: SnapshotError.unsupportedVersion(2)) { try SnapshotFile.decode(data) }
        let url = URL(fileURLWithPath: fx.path("neu.drsnap"))
        try data.write(to: url)
        #expect(throws: SnapshotError.unsupportedVersion(2)) { try SnapshotFile.readMetadata(url) }
    }

    @Test("Ablage: Auflisten, Laden, Umbenennen, Löschen und Aufräumen")
    func storeManagement() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        let s = store(fx)
        #expect(try s.list().isEmpty)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var infos: [SnapshotInfo] = []
        for i in 0 ..< 5 {
            infos.append(try s.save(r, name: "nr\(i)", date: base.addingTimeInterval(Double(i) * 3600)))
        }
        // Gleicher Zeitstempel → eigener Dateiname
        let twin = try s.save(r, name: "zwilling", date: base)
        #expect(twin.url != infos[0].url)
        // Anderer Scan-Wurzel-Pfad
        let other = try ScanEngine().scanBlocking(fx.path("rest"))
        try s.save(other, name: "anderer", date: base)

        let all = try s.list()
        #expect(all.count == 7)
        #expect(all.first?.metadata.name == "nr4") // neueste zuerst
        let mine = try s.list(rootPath: fx.root, volumeUUID: VolumeInfo.forPath(fx.root)?.uuid)
        #expect(mine.count == 6)
        #expect(try s.list(rootPath: fx.root, volumeUUID: "gibt-es-nicht").isEmpty)
        let uuidDir = s.baseDirectory.appendingPathComponent(SnapshotStore.directoryName(for: mine[0].metadata.volumeUUID))
        #expect(mine.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL == uuidDir.standardizedFileURL })
        #expect(mine.allSatisfy { $0.fileSize > 0 })

        // Umbenennen
        let renamed = try s.rename(infos[2], to: "vor Xcode-Update")
        #expect(renamed.metadata.name == "vor Xcode-Update")
        #expect(try s.load(renamed).metadata.name == "vor Xcode-Update")
        #expect(try s.load(renamed).tree.isIdentical(to: try s.load(infos[3]).tree))
        #expect(try s.list().contains { $0.metadata.name == "vor Xcode-Update" })

        // Löschen
        try s.delete(twin)
        #expect(!FileManager.default.fileExists(atPath: twin.url.path))
        #expect(throws: SnapshotError.self) {
            try s.delete(SnapshotInfo(url: URL(fileURLWithPath: fx.path("gross/a.bin")), metadata: twin.metadata, fileSize: 0))
        }
        #expect(FileManager.default.fileExists(atPath: fx.path("gross/a.bin")))

        // Aufräumen auf höchstens 3 pro Scan-Wurzel: die ältesten gehen.
        let removed = try s.prune(maxCount: 3, rootPath: fx.root)
        #expect(removed.map { $0.metadata.name } == ["nr1", "nr0"])
        #expect(try s.list(rootPath: fx.root).map { $0.metadata.name } == ["nr4", "nr3", "vor Xcode-Update"])
        #expect(try s.list(rootPath: fx.path("rest")).count == 1)
        #expect(try s.prune(maxCount: 3, rootPath: fx.root).isEmpty)
    }

    @Test("Standard-Ablageort unter Application Support")
    func defaultLocation() {
        let p = SnapshotStore.defaultBaseDirectory.path
        #expect(p.hasSuffix("Library/Application Support/DiskRings/Snapshots"))
        #expect(SnapshotStore().minimumFileSize == 1_000_000)
    }

    @Test("Snapshot eines Baums mit toten Knoten (nach Teil-Rescan) wird kompakt gespeichert")
    func snapshotAfterRescan() throws {
        let fx = try Fixture()
        let r = try sampleScan(fx)
        try fx.file("gross/neu.bin", size: 2_000_000)
        let sub = try ScanEngine().scanBlocking(fx.path("gross")).tree
        let edit = r.tree.replacingSubtree(at: try #require(r.tree.index(ofPath: "gross")), with: sub,
                                           compactIfNeeded: false)
        #expect(edit.tree.deadCount > 0)
        let s = store(fx, min: 0)
        let loaded = try s.load(try s.save(edit.tree, metadata: SnapshotMetadata(rootPath: fx.root)))
        #expect(loaded.tree.deadCount == 0)
        expectValidTree(loaded.tree)
        expectEquivalent(loaded.tree, edit.tree)
    }
}
