@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Vergleichsmodus mit echtem Scan (Beispiel aus der Vorschau)", .timeLimit(.minutes(2)))
struct CompareDemoTests {
    @Test("Akzeptanz: neuer großer Ordner zuerst, sein Elternordner dominiert den Wachstums-Sunburst")
    func acceptance() throws {
        let fx = try Fixture()
        let home = try fx.dir("home")
        try CompareDemo.createInitial(at: home)
        let engine = ScanEngine(options: ScanOptions(workerCount: 2))
        // Ablage im Fixture-Ordner (Standard-Mindestgröße 1 MB wie in der App).
        let store = SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("ablage")))
        let saved = try store.save(try engine.scanBlocking(home), date: Date(timeIntervalSinceNow: -86_400))
        try CompareDemo.applyChanges(at: home)
        let r = try engine.scanBlocking(home)
        let diff = SnapshotDiff(old: try store.load(saved), new: Snapshot(metadata: .current(for: r), tree: r.tree))
        let m = CompareModel(diff: diff)
        #expect(m.warningTexts.isEmpty)

        let top = m.largestChanges()
        let first = try #require(top.first)
        #expect(first.path == home + "/" + CompareDemo.newFolder)
        #expect(first.status == .added)

        let g = m.layout(.growth, focusEntry: 0, options: SunburstOptions())
        let biggest = try #require(g.arcs(inRing: 1).max { $0.span < $1.span })
        #expect(m.diff.name(of: try #require(m.entry(for: biggest, view: .growth))) == CompareDemo.newFolderParent)
        #expect(biggest.span > .pi) // mehr als die Hälfte des Zuwachses

        // Delta-Ansicht: entferntes Album und gelöschter Film sichtbar als „entfernt“.
        let d = m.layout(.delta, focusEntry: 0, options: SunburstOptions())
        var statuses: [String: DiffStatus] = [:]
        for a in d.arcs {
            if let e = m.entry(for: a, view: .delta) { statuses[m.diff.path(of: e)] = m.status(of: a, view: .delta) }
        }
        #expect(statuses[home + "/Music/Album B"] == .removed)
        #expect(statuses[home + "/Movies/Vacation 2025.mov"] == .removed)
        #expect(statuses[home + "/" + CompareDemo.newFolder] == .added)
        #expect(statuses[home + "/Downloads/photo-export.zip"] == .shrunk)
    }

    @Test("Demo-Fixture schreibt nur unterhalb der Wurzel")
    func pathGuard() {
        #expect(throws: (any Error).self) { try CompareDemo.checkedPath("/tmp/x", "../y") }
        #expect(throws: (any Error).self) { try CompareDemo.checkedPath("/tmp/x", "/etc/z") }
        #expect(throws: (any Error).self) { try CompareDemo.checkedPath("/tmp/x", "") }
        #expect((try? CompareDemo.checkedPath("/tmp/x", "a/b")) == "/tmp/x/a/b")
    }
}
