@testable import DiskRingsCore
import Foundation
import Testing

/// Beispielbäume für Vorschaubilder und App-Store-Screenshots.
@Suite("Demo-Baum")
struct DemoTreeTests {
    @Test("Standardaufruf bleibt unverändert")
    func defaultUnchanged() {
        let a = DemoTree.home()
        let b = DemoTree.home(rootPath: "/Users/demo", scale: 1, afterChanges: false)
        #expect(a.isIdentical(to: b))
        #expect(a.index(ofPath: "Empty") != nil)
    }

    @Test("Skalierung vervielfacht die Größen, nicht die Struktur")
    func scaled() {
        let a = DemoTree.home(), b = DemoTree.home(scale: 2)
        expectValidTree(b)
        #expect(a.count == b.count)
        let ratio = Double(b.root.allocatedSize) / Double(a.root.allocatedSize)
        #expect(ratio > 1.95 && ratio <= 2.0)
        #expect(b.root.allocatedSize > 400_000_000_000)
    }

    @Test("Stand nach Änderungen: neue, gewachsene, geschrumpfte und entfernte Einträge")
    func afterChanges() throws {
        let before = DemoTree.home(scale: 2), after = DemoTree.home(scale: 2, afterChanges: true)
        expectValidTree(after)
        #expect(after.isIdentical(to: DemoTree.home(scale: 2, afterChanges: true)))
        #expect(before.index(ofPath: DemoTree.newFolder) == nil)
        #expect(after.index(ofPath: DemoTree.newFolder) != nil)
        #expect(before.index(ofPath: "Movies/Vacation 9.mov") != nil)
        #expect(after.index(ofPath: "Movies/Vacation 9.mov") == nil)

        func meta(_ t: ScanTree) -> SnapshotMetadata {
            SnapshotMetadata(rootPath: t.rootPath, allocatedSize: t.root.allocatedSize,
                             logicalSize: t.root.logicalSize, fileCount: UInt64(t.root.fileCount),
                             nodeCount: t.liveCount)
        }
        let diff = SnapshotDiff(old: Snapshot(metadata: meta(before), tree: before),
                                new: Snapshot(metadata: meta(after), tree: after))
        let statuses = Set((0 ..< Int32(diff.count)).map { diff.status($0) })
        #expect(statuses.isSuperset(of: [.added, .removed, .grown, .shrunk, .unchanged]))
        // Insgesamt gewachsen, der neue Ordner ist die größte Veränderung.
        #expect(diff.delta(0) > 0)
        #expect(diff.largestChanges(limit: 1).first?.path == "/Users/demo/" + DemoTree.newFolder)
    }
}

@Suite("ScanResult ohne Scan")
struct ScanResultMakeTests {
    @Test("Kennzahlen kommen aus dem Baum")
    func fromTree() {
        let t = DemoTree.home()
        let r = ScanResult.make(tree: t, duration: 12.5)
        #expect(r.fileCount == t.root.fileCount)
        #expect(r.directoryCount == t.directoryCount)
        #expect(r.duration == 12.5)
        #expect(r.allocatedSize == t.root.allocatedSize)
        #expect(r.unreadablePaths.isEmpty && r.skippedMountPoints.isEmpty)
        #expect(ScanSummary(r).rootPath == "/Users/demo")
    }
}
