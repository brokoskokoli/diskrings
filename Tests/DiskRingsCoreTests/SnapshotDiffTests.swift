@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Snapshot-Vergleich", .timeLimit(.minutes(3)), .language("de"))
struct SnapshotDiffTests {
    let engine = ScanEngine(options: ScanOptions(workerCount: 2))

    func live(_ path: String, date: Date = Date()) throws -> Snapshot {
        let r = try engine.scanBlocking(path)
        return Snapshot(metadata: .current(for: r, date: date), tree: r.tree)
    }

    func store(_ fx: Fixture) -> SnapshotStore {
        SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("snapshots-ablage")))
    }

    @Test("Akzeptanz (SPEC 9): Snapshot, Dateien in Downloads/x anlegen, Vergleich")
    func acceptanceScenario() throws {
        let fx = try Fixture()
        let home = try fx.dir("home")
        try fx.file("home/Downloads/alt.zip", size: 3_000_000)
        try fx.file("home/Library/Caches/c.bin", size: 4_000_000)
        try fx.file("home/Library/Prefs/klein.plist", size: 3000)
        try fx.file("home/Dokumente/brief.pdf", size: 1_500_000)
        let s = store(fx)
        let saved = try s.save(try engine.scanBlocking(home), date: Date(timeIntervalSinceNow: -3600))
        let before = try s.load(saved)

        // „5 GB in ~/Downloads/x“ – hier 5 echte Dateien à 2 MB.
        var added: UInt64 = 0
        for i in 0 ..< 5 { added += Fixture.allocated(try fx.file("home/Downloads/x/teil\(i).bin", size: 2_000_000)) }
        try fx.file("home/Library/Caches/c2.bin", size: 1_200_000) // kleinere Nebenänderung
        let after = try live(home)

        let diff = SnapshotDiff(old: before, new: after)
        #expect(diff.warnings.isEmpty)
        let top = diff.largestChanges(limit: 50)
        let first = try #require(top.first)
        #expect(first.path == fx.path("home/Downloads/x"))
        #expect(first.name == "x")
        #expect(first.delta == Int64(added))
        #expect(first.status == .added)
        #expect(top.map(\.name) == ["x", "c2.bin"])

        let x = try #require(diff.entry(forPath: fx.path("home/Downloads/x")))
        #expect(diff.status(x) == .added)
        let downloads = try #require(diff.entry(forPath: fx.path("home/Downloads")))
        #expect(diff.status(downloads) == .grown)
        #expect(diff.delta(downloads) == Int64(added))
        let alt = try #require(diff.entry(forPath: fx.path("home/Downloads/alt.zip")))
        #expect(diff.status(alt) == .unchanged)

        // Wachstums-Sunburst: Downloads ist das dominierende Segment.
        let (growth, map) = diff.growthTree()
        expectValidTree(growth)
        #expect(growth.rootPath == home)
        let kids = growth.root.children
        #expect(kids.first?.name == "Downloads")
        #expect(kids.first!.allocatedSize * 2 > growth.root.allocatedSize)
        #expect(growth.root.allocatedSize == diff.delta(0))
        #expect(growth.index(ofPath: "Dokumente") == nil) // kein Wachstum
        let gx = try #require(growth.index(ofPath: "Downloads/x"))
        #expect(map[Int(gx)] == x)
        #expect(growth.node(gx).allocatedSize == added)

        // Kopfzeile
        #expect(diff.summary.scanDelta == Int64(added) + diff.delta(try #require(diff.entry(forPath: fx.path("home/Library/Caches/c2.bin")))))
        #expect(diff.summary.headline.hasPrefix("Seit "))
    }

    @Test("Umbenannter Ordner erscheint als „entfernt“ plus „neu“")
    func renamedFolder() throws {
        let fx = try Fixture()
        try fx.file("projekt-alt/a.bin", size: 2_000_000)
        try fx.file("projekt-alt/z.bin", size: 2_000_000)
        try fx.file("bleibt/b.bin", size: 1_500_000)
        let before = try live(fx.root)
        #expect(rename(fx.path("projekt-alt"), fx.path("projekt-neu")) == 0)
        let after = try live(fx.root)
        let diff = SnapshotDiff(old: before, new: after)
        let alt = try #require(diff.entry(forPath: fx.path("projekt-alt")))
        let neu = try #require(diff.entry(forPath: fx.path("projekt-neu")))
        #expect(diff.status(alt) == .removed)
        #expect(diff.status(neu) == .added)
        #expect(diff.delta(alt) == -diff.delta(neu))
        #expect(diff.status(0) == .unchanged)
        #expect(diff.entries[Int(alt)].newIndex == -1)
        #expect(diff.entries[Int(neu)].oldIndex == -1)
        // Kinder entfernter Ordner sind ebenfalls „entfernt“.
        let altA = try #require(diff.entry(forPath: fx.path("projekt-alt/a.bin")))
        #expect(diff.status(altA) == .removed)
        #expect(diff.largestChanges().map(\.name) == ["projekt-neu"])
        #expect(diff.largestChanges(growth: false).map(\.name) == ["projekt-alt"])
        let change = try #require(diff.largestChanges().first)
        #expect(change.delta == change.newSize.asInt64 && change.amount == change.newSize)
    }

    @Test("Status und Delta pro Knoten; Zuordnung zu beiden Bäumen")
    func statusPerNode() throws {
        let fx = try Fixture()
        try fx.file("w/wachsen.bin", size: 1_100_000)
        try fx.file("w/schrumpfen.bin", size: 3_000_000)
        try fx.file("w/gleich.bin", size: 1_200_000)
        try fx.file("w/weg.bin", size: 1_300_000)
        let before = try live(fx.root)
        try fx.file("w/wachsen.bin", size: 2_500_000)
        try fx.file("w/schrumpfen.bin", size: 1_000_000)
        unlink(fx.path("w/weg.bin"))
        try fx.file("w/neu.bin", size: 1_400_000)
        let after = try live(fx.root)
        let diff = SnapshotDiff(old: before, new: after)
        func st(_ n: String) -> DiffStatus? { diff.entry(forPath: fx.path("w/" + n)).map { diff.status($0) } }
        #expect(st("wachsen.bin") == .grown)
        #expect(st("schrumpfen.bin") == .shrunk)
        #expect(st("gleich.bin") == .unchanged)
        #expect(st("weg.bin") == .removed)
        #expect(st("neu.bin") == .added)
        let w = try #require(diff.entry(forPath: fx.path("w")))
        #expect(diff.childEntries(of: w).count == 5)
        #expect(diff.delta(w) == Int64(after.tree.root.allocatedSize) - Int64(before.tree.root.allocatedSize))
        let sorted = diff.childEntriesSortedByDelta(of: w).map { diff.name(of: $0) }
        #expect(sorted.first == "wachsen.bin" || sorted.first == "neu.bin")
        #expect(sorted.last == "schrumpfen.bin")
        // Zuordnung neuer Baum → Eintrag
        for i in 0 ..< Int32(after.tree.count) {
            let e = diff.entryForNew[Int(i)]
            #expect(e >= 0)
            #expect(diff.entries[Int(e)].newIndex == i)
        }
        #expect(diff.oldSize(0) == before.tree.root.allocatedSize)
        #expect(diff.newSize(0) == after.tree.root.allocatedSize)
    }

    @Test("Größte Veränderungen: nur der tiefste aussagekräftige Ordner")
    func deepestMeaningful() throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/foo/vorher.bin", size: 1_000_000)
        try fx.file("Library/Containers/bar/vorher.bin", size: 1_000_000)
        try fx.file("Library/Breit/vorher.bin", size: 1_000_000)
        try fx.file("anderes/x.bin", size: 1_000_000)
        let before = try live(fx.root)
        // foo wächst um 8 Dateien (über viele Dateien verteilt → foo selbst)
        for i in 0 ..< 8 { try fx.file("Library/Caches/foo/neu\(i).bin", size: 1_500_000) }
        // bar wächst um eine große Datei (→ die Datei selbst)
        try fx.file("Library/Containers/bar/riesig.bin", size: 6_000_000)
        // Breit: viele Unterordner mit je kleinem Zuwachs unter der Schwelle
        for i in 0 ..< 10 { try fx.file("Library/Breit/u\(i)/d.bin", size: 300_000) }
        let after = try live(fx.root)
        let diff = SnapshotDiff(old: before, new: after, minimumFileSize: 0)
        let top = diff.largestChanges(limit: 10)
        let names = top.map(\.path).map { String($0.dropFirst(fx.root.count + 1)) }
        #expect(names == ["Library/Caches/foo", "Library/Containers/bar/riesig.bin", "Library/Breit"])
        // Nie Vorfahren voneinander
        for a in top { for b in top where a.entry != b.entry { #expect(!b.path.hasPrefix(a.path + "/")) } }
        #expect(diff.largestChanges(limit: 1).count == 1)
        #expect(diff.largestChanges(minimumDelta: 7_000_000).map(\.name) == ["foo"])
    }

    @Test("Kleine Dateien des frischen Scans erscheinen nicht als „neu“ gegenüber einem Snapshot mit Mindestgröße")
    func smallFilesAgainstCondensed() throws {
        let fx = try Fixture()
        try fx.file("d/gross.bin", size: 2_000_000)
        for i in 0 ..< 5 { try fx.file("d/klein\(i).txt", size: 5000) }
        let s = store(fx)
        let before = try s.load(try s.save(try engine.scanBlocking(fx.path("d"))))
        let after = try live(fx.path("d"))
        let diff = SnapshotDiff(old: before, new: after)
        #expect(diff.minimumFileSize == 1_000_000)
        #expect(diff.count == 2) // Wurzel + gross.bin
        #expect(diff.status(0) == .unchanged)
        #expect(diff.largestChanges().isEmpty)
        #expect(diff.warnings.isEmpty) // frischer Scan ohne Mindestgröße ist der Normalfall
        let klein = try #require(after.tree.index(ofPath: "klein0.txt"))
        #expect(diff.entryForNew[Int(klein)] == -1)
    }

    @Test("Warnung bei abweichenden Scan-Optionen; Kopfzeile mit Volume-Kennzahlen")
    func warningsAndHeadline() throws {
        let fx = try Fixture()
        try fx.file("a/.versteckt", size: 2_000_000)
        try fx.file("a/sichtbar.bin", size: 1_000_000)
        let r1 = try ScanEngine(options: ScanOptions(includeHidden: false)).scanBlocking(fx.root)
        let r2 = try engine.scanBlocking(fx.root)
        var m1 = SnapshotMetadata.current(for: r1, date: Date(timeIntervalSince1970: 1_791_000_000))
        var m2 = SnapshotMetadata.current(for: r2)
        m1.volume = VolumeMetrics(name: "HD", total: 1000_000_000_000, available: 400_000_000_000,
                                  availableForImportantUsage: 410_000_000_000, used: 600_000_000_000,
                                  unassigned: 50_000_000_000)
        m2.volume = VolumeMetrics(name: "HD", total: 1000_000_000_000, available: 361_800_000_000,
                                  availableForImportantUsage: 370_000_000_000, used: 638_200_000_000,
                                  unassigned: 54_100_000_000)
        let diff = SnapshotDiff(old: Snapshot(metadata: m1, tree: r1.tree), new: Snapshot(metadata: m2, tree: r2.tree))
        #expect(diff.warnings.contains { if case .differentOptions = $0 { true } else { false } })
        #expect(diff.warnings.first?.description.contains("vorher ohne versteckte Dateien") == true)
        #expect(diff.summary.usedDelta == 38_200_000_000)
        #expect(diff.summary.freeDelta == -38_200_000_000)
        #expect(diff.summary.unassignedDelta == 4_100_000_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM., HH:mm"
        let expected = "Seit \(f.string(from: m1.date)): belegt +38,2\u{00A0}GB · frei \u{2212}38,2\u{00A0}GB · davon nicht zugeordnet +4,1\u{00A0}GB"
        #expect(diff.summary.headline == expected)
    }

    @Test("Snapshot gegen Snapshot ohne neuen Scan, über den Store geladen")
    func snapshotVsSnapshot() throws {
        let fx = try Fixture()
        try fx.file("a.bin", size: 1_500_000)
        let s = store(fx)
        let i1 = try s.save(try engine.scanBlocking(fx.root), date: Date(timeIntervalSinceNow: -100))
        try fx.file("b.bin", size: 2_500_000)
        let i2 = try s.save(try engine.scanBlocking(fx.root))
        let diff = SnapshotDiff(old: try s.load(i1), new: try s.load(i2))
        #expect(diff.largestChanges().map(\.name).contains("b.bin"))
        #expect(diff.status(0) == .grown)
    }

    @Test("Performance: Vergleich von 2 × 2 Mio. synthetischen Knoten unter 2 s")
    func performance() throws {
        let a = try RescanTests.syntheticTree()
        let b = try RescanTests.syntheticTree() // andere Zufallsgrößen → andere Reihenfolge
        let old = Snapshot(metadata: SnapshotMetadata(rootPath: a.rootPath), tree: a)
        let new = Snapshot(metadata: SnapshotMetadata(rootPath: b.rootPath), tree: b)
        let start = DispatchTime.now().uptimeNanoseconds
        let diff = SnapshotDiff(old: old, new: new, minimumFileSize: 0)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("[perf] Vergleich \(a.count) gegen \(b.count) Knoten: \(seconds) s")
        #expect(diff.count == a.count)
        #expect(diff.entryForNew.allSatisfy { $0 >= 0 })
        // Ziel (SPEC 3.9): unter 2 s. Geprüft im Release-Build (scripts/check.sh
        // führt die Performance-Tests zusätzlich mit -c release aus); der
        // Debug-Build ist etwa 15× langsamer.
        #if DEBUG
        let limit = 30.0
        #else
        let limit = 2.0
        #endif
        #expect(seconds < limit, "Vergleich dauerte \(seconds) s")
        let t2 = DispatchTime.now().uptimeNanoseconds
        _ = diff.largestChanges()
        let (g, _) = diff.growthTree()
        print("[perf] Größte Veränderungen + Wachstumsbaum (\(g.count) Knoten): \(Double(DispatchTime.now().uptimeNanoseconds - t2) / 1e9) s")
    }
}

extension UInt64 {
    var asInt64: Int64 { Int64(self) }
}
