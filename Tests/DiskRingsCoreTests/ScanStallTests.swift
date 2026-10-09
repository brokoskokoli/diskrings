@testable import DiskRingsCore
import Foundation
import Testing

/// Abnahme-Befund: Ein Scan, der an einer macOS-Datenschutzabfrage (TCC)
/// hängt, soll als „wartet auf Freigabe“ erkannt werden; vor dem ersten
/// Scan von / oder ~ ohne Festplattenvollzugriff gibt es einen Hinweis.
@Suite("Scan: Stillstand und Hinweis auf den Festplattenvollzugriff")
struct ScanStallTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func progress(files: Int, dirs: Int, bytes: UInt64 = 0) -> ScanProgress {
        .make(filesScanned: files, directoriesScanned: dirs, allocatedBytes: bytes, currentPath: "/x", elapsed: 0)
    }

    @Test("Ohne neue Dateien länger als 3 s → Stillstand; neue Dateien setzen ihn zurück")
    func stall() {
        var d = ScanStallDetector(start: t0)
        #expect(ScanStallDetector.defaultThreshold == 3)
        #expect(!d.isStalled(at: t0.addingTimeInterval(2.9)))
        // Noch gar kein Fortschritt (z. B. hängt schon die Scan-Wurzel ~/Downloads).
        #expect(d.isStalled(at: t0.addingTimeInterval(3.1)))

        d.observe(progress(files: 10, dirs: 2), at: t0.addingTimeInterval(1))
        #expect(!d.isStalled(at: t0.addingTimeInterval(3.5)))
        // Gleiche Zähler, weitere Meldungen alle 250 ms: zählt nicht als Bewegung.
        for i in 1 ... 20 { d.observe(progress(files: 10, dirs: 2), at: t0.addingTimeInterval(1 + Double(i) * 0.25)) }
        #expect(!d.isStalled(at: t0.addingTimeInterval(3.9)))
        #expect(d.isStalled(at: t0.addingTimeInterval(4.1)))
        #expect(d.stalledFor(at: t0.addingTimeInterval(6)) == 5)

        // Bewegung (ein neuer Ordner reicht) → kein Stillstand mehr.
        d.observe(progress(files: 10, dirs: 3), at: t0.addingTimeInterval(6))
        #expect(!d.isStalled(at: t0.addingTimeInterval(8.9)))
        #expect(d.stalledFor(at: t0.addingTimeInterval(7)) == nil)
        #expect(d.isStalled(at: t0.addingTimeInterval(9.1)))
    }

    @Test("Herzschlag (gelesener Block in einem großen Ordner) zählt als Bewegung")
    func heartbeatCountsAsMovement() {
        var d = ScanStallDetector(start: t0)
        var p = progress(files: 5, dirs: 1)
        d.observe(p, at: t0)
        // Ein Ordner mit 1 Mio. Dateien: Zähler stehen 8 s, aber Blöcke kommen.
        for i in 1 ... 8 {
            p.heartbeat += 1
            d.observe(p, at: t0.addingTimeInterval(Double(i)))
        }
        #expect(!d.isStalled(at: t0.addingTimeInterval(10.9)))
        #expect(d.isStalled(at: t0.addingTimeInterval(11.1)))
    }

    @Test("Nur gelesene Bytes ohne neue Einträge zählen nicht als Bewegung; eigene Schwelle")
    func bytesOnlyAndThreshold() {
        var d = ScanStallDetector(start: t0, threshold: 5)
        d.observe(progress(files: 1, dirs: 1, bytes: 100), at: t0)
        d.observe(progress(files: 1, dirs: 1, bytes: 200), at: t0.addingTimeInterval(2))
        #expect(!d.isStalled(at: t0.addingTimeInterval(4.9)))
        #expect(d.isStalled(at: t0.addingTimeInterval(5.1)))
    }

    @Test("Hinweis-Dialog nur vor einem Scan von / oder ~ und nur ohne Festplattenvollzugriff")
    func fullDiskAccessHint() {
        let home = "/Users/demo"
        func warn(_ path: String, _ status: FullDiskAccess.Status = .denied, dismissed: Bool = false) -> Bool {
            FullDiskAccess.shouldWarnBeforeScan(of: path, home: home, status: status, dismissed: dismissed)
        }
        #expect(warn("/"))
        #expect(warn("/Users/demo"))
        #expect(warn("/Users/demo/"))
        #expect(warn("/System/Volumes/Data")) // Datenvolume = dieselben Inhalte wie /
        #expect(warn("/users/DEMO")) // ohne Groß-/Kleinschreibung
        #expect(!warn("/Users/demo/Projekte"))
        #expect(!warn("/Volumes/Extern"))
        #expect(!warn("/", .granted))
        #expect(!warn("/", .unknown))
        #expect(!warn("/Users/demo", dismissed: true))
    }
}
