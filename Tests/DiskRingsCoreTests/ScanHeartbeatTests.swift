@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Nachprüfung: Herzschlag des Scans, damit ein großer Ordner nicht als
/// Stillstand gilt.
@Suite("Nachprüfung: Herzschlag des Scans", .timeLimit(.minutes(2)))
struct ScanHeartbeatTests {
    let fm = FileManager.default

    func scan(_ fx: Fixture) throws -> ScanResult {
        try fx.file("daten/a.bin", size: 1_500_000)
        return try ScanEngine(options: ScanOptions(workerCount: 1)).scanBlocking(fx.path("daten"))
    }

    // MARK: 4. Herzschlag

    @Test("DirectoryReader meldet jeden getattrlistbulk-Block; großer Ordner → mehrere Herzschläge")
    func readerHeartbeat() throws {
        let fx = try Fixture()
        let dir = try fx.dir("gross")
        for i in 0 ..< 6000 {
            let fd = open(dir + "/datei-mit-etwas-laengerem-namen-\(i).txt", O_WRONLY | O_CREAT, 0o644)
            if fd >= 0 { close(fd) }
        }
        var reader = DirectoryReader()
        let fd = openDirectory(dir)
        #expect(fd >= 0)
        defer { close(fd) }
        var blocks = 0
        var entries = 0
        let err = reader.read(fd: fd, shouldStop: { false }, onBlock: { blocks += 1 }) { _ in entries += 1 }
        #expect(err == 0)
        #expect(entries == 6000)
        #expect(blocks >= 2)
    }

    @Test("ScanEngine meldet den Herzschlag im Fortschritt")
    func engineHeartbeat() throws {
        let fx = try Fixture()
        try fx.file("a/x.bin", size: 10)
        try fx.file("b/y.bin", size: 10)
        let last = Locked<ScanProgress?>(nil)
        _ = try ScanEngine(options: ScanOptions(workerCount: 1, progressInterval: 0.01))
            .scanBlocking(fx.root, onProgress: { p in last.set(p) })
        let p = try #require(last.get())
        #expect(p.heartbeat >= 3) // Wurzel, a, b
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.lock(); defer { l.unlock() }; return v }
    func set(_ n: T) { l.lock(); v = n; l.unlock() }
}
