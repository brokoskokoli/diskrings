@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Abnahme-Befund: Nach Papierkorb oder Teil-Rescan hielt die App über
/// `ScanResult` den ursprünglichen Baum fest (zwei Baumversionen im
/// Speicher), und das Zusammenfassungs-Banner zeigte die alten Zahlen.
/// `ScanSummary` trägt nur die Kennzahlen, ohne Baum.
@Suite("Scan-Zusammenfassung ohne Baum", .timeLimit(.minutes(1)))
struct ScanSummaryTests {
    func scan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("a/x.bin", size: 100_000)
        try fx.file("a/y.bin", size: 50_000)
        try fx.file("b/z.bin", size: 30_000)
        try fx.file("b/tief/w.bin", size: 10_000)
        return try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.root)
    }

    @Test("Übernimmt die Kennzahlen und hält den Baum nicht fest")
    func doesNotRetainTree() throws {
        let fx = try Fixture()
        weak var weakTree: ScanTree?
        var summary: ScanSummary?
        try autoreleasepool {
            let r = try scan(fx)
            weakTree = r.tree
            summary = ScanSummary(r)
            let s = try #require(summary)
            #expect(s.rootPath == r.tree.rootPath)
            #expect(s.fileCount == r.fileCount && s.directoryCount == r.directoryCount)
            #expect(s.allocatedSize == r.allocatedSize && s.logicalSize == r.logicalSize)
            #expect(s.duration == r.duration && s.options == r.options)
            #expect(s.unreadablePaths == r.unreadablePaths)
        }
        #expect(summary != nil)
        #expect(weakTree == nil, "ScanSummary darf den Baum des Scans nicht festhalten")
    }

    @Test("Nach einer Änderung am Baum: aktuelle Dateien, Ordner und Größe; Dauer und Optionen bleiben")
    func updatedAfterEdit() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let s0 = ScanSummary(r)
        let b = try #require(r.tree.index(ofPath: "b"))
        let edited = r.tree.removingNodes([b]).tree
        let s1 = s0.updated(for: edited)
        #expect(s1.fileCount == r.fileCount - 2)
        #expect(s1.directoryCount == r.directoryCount - 2)
        #expect(s1.allocatedSize == edited.root.allocatedSize)
        #expect(s1.allocatedSize < s0.allocatedSize)
        #expect(s1.logicalSize == edited.root.logicalSize)
        #expect(s1.duration == s0.duration && s1.options == s0.options && s1.rootPath == s0.rootPath)
    }

    @Test("Nicht lesbare Ordner: entfernte fallen aus der Liste")
    func unreadableFiltered() throws {
        let fx = try Fixture()
        try fx.file("offen/a.bin", size: 1000)
        try fx.file("zu1/geheim.bin", size: 1000)
        try fx.file("zu2/geheim.bin", size: 1000)
        chmod(fx.path("zu1"), 0)
        chmod(fx.path("zu2"), 0)
        defer {
            chmod(fx.path("zu1"), 0o755)
            chmod(fx.path("zu2"), 0o755)
        }
        let r = try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.root)
        let s0 = ScanSummary(r)
        #expect(Set(s0.unreadablePaths) == [fx.path("zu1"), fx.path("zu2")])
        let zu1 = try #require(r.tree.index(ofPath: "zu1"))
        let s1 = s0.updated(for: r.tree.removingNodes([zu1]).tree)
        #expect(s1.unreadablePaths == [fx.path("zu2")])
    }

    @Test("Snapshot-Metadaten aus Zusammenfassung und aktuellem Baum")
    func metadataFromSummary() throws {
        let fx = try Fixture()
        let r = try scan(fx)
        let b = try #require(r.tree.index(ofPath: "b"))
        let edited = r.tree.removingNodes([b]).tree
        let m = SnapshotMetadata.current(for: ScanSummary(r), tree: edited, name: "x")
        #expect(m.rootPath == r.tree.rootPath)
        #expect(m.allocatedSize == edited.root.allocatedSize)
        #expect(m.fileCount == UInt64(edited.root.fileCount))
        #expect(m.options == SnapshotScanOptions(r.options))
        #expect(m.name == "x")
    }
}
