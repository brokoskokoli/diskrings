@testable import DiskRingsCore
import Foundation
import Testing

@MainActor
@Suite("ScanController", .serialized)
struct ScanControllerTests {
    final class Recorder {
        var events: [(gen: UInt64, root: String?, kind: String)] = []
    }

    /// Wartet (höchstens `timeout` Sekunden), bis `condition` erfüllt ist.
    func wait(_ timeout: Double = 20, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func bigFixture() throws -> Fixture {
        let f = try Fixture()
        for d in 0 ..< 300 {
            for i in 0 ..< 15 { try f.file("a\(d)/f\(i)", size: 10) }
        }
        return f
    }

    func record(_ c: ScanController, into rec: Recorder) {
        c.handler = { [unowned c] e in
            switch e {
            case .progress: rec.events.append((c.generation, nil, "progress"))
            case .snapshot(let t): rec.events.append((c.generation, t.rootPath, "snapshot"))
            case .finished(let r): rec.events.append((c.generation, r.tree.rootPath, "finished"))
            case .failed: rec.events.append((c.generation, nil, "failed"))
            }
        }
    }

    @Test("Neuer Scan: Ereignisse des alten Scans kommen nicht mehr an")
    func restartDropsOldEvents() async throws {
        let a = try bigFixture()
        let b = try Fixture()
        defer { a.remove(); b.remove() }
        try b.file("x/klein", size: 5)
        let c = ScanController()
        let rec = Recorder()
        record(c, into: rec)
        let fast = ScanOptions(workerCount: 2, progressInterval: 0.0002, snapshotDepth: 2)
        // Mehrfach wiederholen, damit gepufferte Ereignisse sicher auftreten.
        for _ in 0 ..< 5 {
            rec.events.removeAll()
            c.start(a.root, options: fast)
            await wait { !rec.events.isEmpty }
            c.start(b.root, options: fast)
            let genB = c.generation
            await wait { rec.events.contains { $0.kind == "finished" } }
            try? await Task.sleep(for: .milliseconds(150)) // späte Nachzügler abwarten
            let afterB = rec.events.filter { $0.gen == genB }
            #expect(afterB.allSatisfy { $0.root == nil || $0.root == b.root },
                    "Ereignis des alten Scans nach dem Neustart: \(afterB.filter { $0.root == a.root }.map(\.kind))")
            #expect(afterB.filter { $0.kind == "finished" }.count == 1)
            #expect(!c.isRunning)
        }
    }

    /// Stream, der alle Ereignisse schon vor dem Lesen gepuffert hat und sie
    /// auch nach dem Abbruch des lesenden Tasks noch ausliefert (so wie
    /// `AsyncThrowingStream` gepufferte Elemente nach `finish` weitergibt).
    nonisolated static func bufferedStream(_ path: String) -> AsyncThrowingStream<ScanEvent, Error> {
        var b = ScanTreeBuilder(rootName: path)
        b.file("f", size: 1)
        let tree = b.build(rootPath: path)
        let (stream, cont) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        for _ in 0 ..< 50 { cont.yield(.snapshot(tree)) }
        cont.yield(.finished(ScanResult(tree: tree, duration: 0, fileCount: 1, directoryCount: 1, unreadablePaths: [],
                                        skippedMountPoints: [], hardlinkDuplicates: 0, options: ScanOptions())))
        cont.finish()
        return stream
    }

    @Test("Gepufferte Ereignisse eines ersetzten Scans werden verworfen (deterministisch)")
    func bufferedEventsDropped() async {
        let c = ScanController(makeStream: { path, _, _ in Self.bufferedStream(path) })
        let rec = Recorder()
        record(c, into: rec)
        c.start("/alt")
        c.start("/neu")
        await wait { rec.events.contains { $0.kind == "finished" } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rec.events.contains { $0.root == "/alt" }, "\(rec.events.filter { $0.root == "/alt" }.count) alte Ereignisse")
        #expect(rec.events.filter { $0.kind == "finished" }.map(\.root) == ["/neu"])
        // Abbruch ohne neuen Scan: gar nichts kommt an.
        rec.events.removeAll()
        c.start("/weg")
        c.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rec.events.isEmpty)
    }

    @Test("Abbrechen: danach keine Ereignisse mehr")
    func cancelStopsEvents() async throws {
        let a = try bigFixture()
        defer { a.remove() }
        let c = ScanController()
        let rec = Recorder()
        record(c, into: rec)
        c.start(a.root, options: ScanOptions(workerCount: 2, progressInterval: 0.0002))
        await wait { !rec.events.isEmpty }
        c.cancel()
        let count = rec.events.count
        #expect(!c.isRunning)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(rec.events.count == count)
    }

    @Test("Fehler wird gemeldet, nicht abgebrochene Scans enden mit finished")
    func failureAndFinish() async throws {
        let c = ScanController()
        let rec = Recorder()
        record(c, into: rec)
        c.start("/gibt/es/nicht-\(UUID().uuidString)")
        await wait { !rec.events.isEmpty }
        #expect(rec.events.map(\.kind) == ["failed"])
        #expect(!c.isRunning)
    }
}
