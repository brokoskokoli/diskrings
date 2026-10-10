@testable import DiskRingsCore
import Foundation
import Testing

/// Präparierte `.drsnap`-Dateien: übertriebene Längenangaben dürfen keinen
/// riesigen Speicher anfordern, ungültige Namen gelten als beschädigt.
/// Alle Dateien liegen in temporären Verzeichnissen.
@Suite("Snapshots: präparierte Dateien", .timeLimit(.minutes(1)))
struct SnapshotHostileTests {
    func tree(names: [String] = ["a.bin", "b.bin"]) -> ScanTree {
        var b = ScanTreeBuilder(rootName: "daten")
        for (i, n) in names.enumerated() { b.file(n, size: UInt64(1000 * (i + 1))) }
        return b.build(rootPath: "/daten")
    }

    func encoded(_ t: ScanTree) throws -> Data {
        try SnapshotFile.encode(Snapshot(metadata: SnapshotMetadata(rootPath: t.rootPath, nodeCount: t.count), tree: t))
    }

    /// Offset des Felds „Länge unkomprimiert“.
    func rawLengthOffset(_ data: Data) -> Int {
        var r = Reader(data)
        _ = try? r.bytes(12)
        let headerLength = (try? r.u32()) ?? 0
        return 16 + Int(headerLength)
    }

    func patchU64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset ..< offset + 8, with: $0) }
    }

    func roundTrip(_ data: Data, _ fx: Fixture) throws -> Snapshot {
        let url = URL(fileURLWithPath: fx.path("präpariert.drsnap"))
        try data.write(to: url)
        return try SnapshotStore(baseDirectory: URL(fileURLWithPath: fx.path("ablage"))).load(url: url)
    }

    @Test("Riesige unkomprimierte Länge (64 GB knapp) wird vor dem Dekomprimieren abgelehnt")
    func hugeRawLength() throws {
        let fx = try Fixture()
        var data = try encoded(tree())
        patchU64(&data, at: rawLengthOffset(data), (1 << 36) - 1)
        let error = #expect(throws: SnapshotError.self) { try roundTrip(data, fx) }
        guard case .corrupted(let why) = error else { Issue.record("\(String(describing: error))"); return }
        #expect(why.contains("length"))
    }

    @Test("Unkomprimierte Länge passt nicht zur Knotenzahl der Nutzdaten → beschädigt")
    func rawLengthMismatch() throws {
        let fx = try Fixture()
        var data = try encoded(tree())
        let off = rawLengthOffset(data)
        var r = Reader(data)
        _ = try r.bytes(off)
        let real = try r.u64()
        patchU64(&data, at: off, real + 4096)
        #expect(throws: SnapshotError.self) { try roundTrip(data, fx) }
    }

    @Test("Verhältnis roh/komprimiert ist begrenzt")
    func ratioLimit() {
        #expect(SnapshotFile.plausibleRawLength(1 << 20, compressed: 1 << 20))
        #expect(SnapshotFile.plausibleRawLength(500_000_000, compressed: 50_000_000))
        // Kleine Dateien dürfen immer bis 1 MB entpacken.
        #expect(SnapshotFile.plausibleRawLength(1 << 20, compressed: 10))
        #expect(!SnapshotFile.plausibleRawLength(1 << 34, compressed: 1 << 20))
        #expect(!SnapshotFile.plausibleRawLength(100, compressed: 0))
    }

    @Test("Kopf der Nutzdaten: Knotenzahl und Namenslänge müssen zur Länge passen")
    func payloadPrefix() {
        // 2 Knoten, 10 Byte Namen → 12 + 80 + 10.
        #expect(SnapshotFile.plausiblePayload(count: 2, nameLength: 10, rawLength: 102))
        #expect(!SnapshotFile.plausiblePayload(count: 2, nameLength: 10, rawLength: 103))
        #expect(!SnapshotFile.plausiblePayload(count: 0, nameLength: 0, rawLength: 12))
        // Mehr als 1024 Byte Namen pro Knoten im Schnitt: unmöglich.
        #expect(!SnapshotFile.plausiblePayload(count: 1, nameLength: 2000, rawLength: 12 + 40 + 2000))
    }

    @Test("Ungültige Namen gelten als beschädigt", arguments: ["a/b", "", ".", "..", "x\u{0}y"])
    func invalidNames(_ bad: String) throws {
        let fx = try Fixture()
        let data = try encoded(tree(names: ["ok.bin", bad]))
        #expect(throws: SnapshotError.self) { try roundTrip(data, fx) }
    }

    @Test("Gültige Namen (Unicode, Punkte, Leerzeichen) bleiben lesbar; Wurzel „/“ ist erlaubt")
    func validNames() throws {
        let fx = try Fixture()
        let names = ["Grüße.txt", "...", ".versteckt", "a b", "日本語", "e\u{301}"]
        let s = try roundTrip(try encoded(tree(names: names)), fx)
        #expect(Set(s.tree.childIndices(of: 0).map { s.tree.name(of: $0) }) == Set(names))
        var b = ScanTreeBuilder(rootName: "/")
        b.file("x", size: 1)
        let root = b.build(rootPath: "/")
        #expect(try roundTrip(try encoded(root), fx).tree.count == 2)
    }
}
