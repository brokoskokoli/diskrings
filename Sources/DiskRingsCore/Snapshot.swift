import Compression
import Foundation

/// Scan-Einstellungen, die das Ergebnis beeinflussen und deshalb mit einem
/// Snapshot gespeichert werden (für die Warnung beim Vergleich, SPEC 3.9).
public struct SnapshotScanOptions: Codable, Sendable, Equatable {
    public var includeHidden: Bool
    public var excludedPaths: [String]
    public var crossMountPoints: Bool

    public init(includeHidden: Bool = true, excludedPaths: [String] = [], crossMountPoints: Bool = false) {
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
        self.crossMountPoints = crossMountPoints
    }

    public init(_ o: ScanOptions) {
        self.init(includeHidden: o.includeHidden, excludedPaths: o.excludedPaths.sorted(),
                  crossMountPoints: o.crossMountPoints)
    }
}

/// Volume-Kennzahlen zum Zeitpunkt des Scans (SPEC 3.9).
public struct VolumeMetrics: Codable, Sendable, Equatable {
    public var name: String
    public var total: UInt64
    /// Wirklich frei.
    public var available: UInt64
    /// Frei für wichtige Daten (inklusive bereinigbarem Speicher).
    public var availableForImportantUsage: UInt64
    /// Belegt = Gesamt − wirklich frei.
    public var used: UInt64
    /// „Nicht zugeordnet“ = belegt − Scan-Summe; nur wenn die Scan-Wurzel die
    /// Wurzel des Volumes ist, sonst `nil`.
    public var unassigned: UInt64?
    /// Aufteilung von `unassigned` (nur bei Scan der Volume-Wurzel; optional im
    /// JSON-Kopf, ältere Snapshots laden ohne sie).
    public var breakdown: VolumeBreakdownMetrics?

    public init(name: String, total: UInt64, available: UInt64, availableForImportantUsage: UInt64, used: UInt64,
                unassigned: UInt64?, breakdown: VolumeBreakdownMetrics? = nil) {
        self.name = name
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
        self.used = used
        self.unassigned = unassigned
        self.breakdown = breakdown
    }

    /// Kennzahlen aus `VolumeInfo`; „Nicht zugeordnet“ und seine Aufteilung nur
    /// bei Scan der Volume-Wurzel. `otherVolumes` sind die anderen Volumes des
    /// Containers (siehe `ContainerVolumes.others`).
    public init(_ v: VolumeInfo, scanRoot: String, scanTotal: UInt64, otherVolumes: [ContainerVolume] = []) {
        let isRoot = v.path == scanRoot
        let b = VolumeBreakdown(volume: v, scanned: scanTotal, otherVolumes: otherVolumes)
        self.init(name: v.name, total: v.totalCapacity, available: v.availableCapacity,
                  availableForImportantUsage: v.availableForImportantUsage, used: v.usedCapacity,
                  unassigned: isRoot ? b.unassigned : nil, breakdown: isRoot ? VolumeBreakdownMetrics(b) : nil)
    }
}

/// Aufteilung von „Nicht zugeordnet“ beim Scan einer Volume-Wurzel (SPEC 4.1
/// Punkt 4, siehe `VolumeBreakdown`). Ältere Snapshots haben sie nicht.
public struct VolumeBreakdownMetrics: Codable, Sendable, Equatable {
    /// Andere APFS-Volumes im selben Container (Summe, geklemmt).
    public var otherVolumes: UInt64
    /// Nicht lesbare Systemdaten.
    public var unreadable: UInt64
    /// Löschbar (geklemmt).
    public var purgeable: UInt64
    /// Wirklich frei.
    public var free: UInt64

    public init(otherVolumes: UInt64, unreadable: UInt64, purgeable: UInt64, free: UInt64) {
        self.otherVolumes = otherVolumes
        self.unreadable = unreadable
        self.purgeable = purgeable
        self.free = free
    }

    public init(_ b: VolumeBreakdown) {
        self.init(otherVolumes: b.otherVolumes, unreadable: b.unreadable, purgeable: b.purgeable, free: b.free)
    }

    /// Systemdaten = andere Volumes + nicht lesbar.
    public var systemData: UInt64 { otherVolumes &+ unreadable }
}

/// Beschreibung eines Snapshots (Kopf der `.drsnap`-Datei).
public struct SnapshotMetadata: Codable, Sendable, Equatable {
    public var id: UUID
    /// Optionaler Name, z. B. „vor Xcode-Update“.
    public var name: String?
    public var date: Date
    public var rootPath: String
    public var volumeUUID: String?
    public var volume: VolumeMetrics?
    public var options: SnapshotScanOptions
    /// Dateien unter dieser belegten Größe stecken nur in der Ordnersumme.
    public var minimumFileSize: UInt64
    // Kennzahlen der Scan-Wurzel (für Listen ohne Laden des Baums).
    public var allocatedSize: UInt64
    public var logicalSize: UInt64
    public var fileCount: UInt64
    public var nodeCount: Int

    public init(
        id: UUID = UUID(), name: String? = nil, date: Date = Date(), rootPath: String, volumeUUID: String? = nil,
        volume: VolumeMetrics? = nil, options: SnapshotScanOptions = SnapshotScanOptions(),
        minimumFileSize: UInt64 = 0, allocatedSize: UInt64 = 0, logicalSize: UInt64 = 0, fileCount: UInt64 = 0,
        nodeCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.rootPath = rootPath
        self.volumeUUID = volumeUUID
        self.volume = volume
        self.options = options
        self.minimumFileSize = minimumFileSize
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
        self.nodeCount = nodeCount
    }

    /// Metadaten für einen frischen Scan. Ohne `volume` wird das Volume der
    /// Scan-Wurzel abgefragt, ohne `otherVolumes` die eingehängten anderen
    /// Volumes des Containers (nur beim Scan einer Volume-Wurzel).
    public static func current(for result: ScanResult, volume: VolumeInfo? = nil,
                               otherVolumes: [ContainerVolume]? = nil, name: String? = nil,
                               date: Date = Date()) -> SnapshotMetadata {
        let tree = result.tree
        let v = volume ?? VolumeInfo.forPath(tree.rootPath)
        let others = otherVolumes ?? defaultOtherVolumes(v, scanRoot: tree.rootPath, options: result.options)
        return SnapshotMetadata(
            name: name, date: date, rootPath: tree.rootPath, volumeUUID: v?.uuid,
            volume: v.map { VolumeMetrics($0, scanRoot: tree.rootPath, scanTotal: result.allocatedSize,
                                          otherVolumes: others) },
            options: SnapshotScanOptions(result.options), minimumFileSize: 0,
            allocatedSize: tree.root.allocatedSize, logicalSize: tree.root.logicalSize,
            fileCount: UInt64(tree.root.fileCount), nodeCount: tree.liveCount)
    }

    /// Eingehängte andere Volumes des Containers, wenn die Scan-Wurzel die
    /// Volume-Wurzel ist (ohne `diskutil`), sonst leer.
    static func defaultOtherVolumes(_ v: VolumeInfo?, scanRoot: String, options: ScanOptions) -> [ContainerVolume] {
        guard let v, v.path == scanRoot else { return [] }
        return ContainerVolumes.others(forVolumeAt: v.path, scanRoot: scanRoot,
                                       crossesMountPoints: options.crossMountPoints, lister: nil)
    }
}

/// Ein geladener (oder gerade erstellter) Snapshot: Metadaten plus Baum.
/// Der Baum ist ein normaler `ScanTree`; mit Mindestgröße ist er nicht
/// vollständig (`isComplete == false`), kleine Dateien stecken dann nur in
/// Größe und Dateianzahl ihres Ordners.
public struct Snapshot: Sendable {
    public let metadata: SnapshotMetadata
    public let tree: ScanTree

    public init(metadata: SnapshotMetadata, tree: ScanTree) {
        self.metadata = metadata
        self.tree = tree
    }
}

public enum SnapshotError: Error, Equatable, CustomStringConvertible {
    /// Keine `.drsnap`-Datei (falsche Kennung).
    case notASnapshot
    /// Neuere, unbekannte Formatversion.
    case unsupportedVersion(UInt16)
    /// Datei endet vorzeitig.
    case truncated
    /// Inhalt beschädigt (Prüfsumme, Dekompression oder Struktur).
    case corrupted(String)
    /// Pfad liegt nicht im Snapshot-Verzeichnis.
    case outsideStore(String)

    public var description: String {
        switch self {
        case .notASnapshot: L("error.snapshot.notASnapshot")
        case .unsupportedVersion(let v): L("error.snapshot.unsupportedVersion", String(v))
        case .truncated: L("error.snapshot.truncated")
        case .corrupted(let why): L("error.snapshot.corrupted", why)
        case .outsideStore(let p): L("error.snapshot.outsideStore", p)
        }
    }
}

/// Binärformat `.drsnap` (alle Zahlen little-endian):
///
/// | Feld | Größe |
/// |---|---|
/// | Kennung `DRSNAP\0\u{1A}` | 8 |
/// | Formatversion (UInt16), reserviert (UInt16) | 4 |
/// | Länge des Kopfs (UInt32) | 4 |
/// | Kopf: `SnapshotMetadata` als JSON (UTF-8, unkomprimiert) | n |
/// | Länge der Nutzdaten unkomprimiert, komprimiert (je UInt64) | 16 |
/// | Prüfsumme der komprimierten Nutzdaten (FNV-1a, UInt64) | 8 |
/// | Nutzdaten, LZFSE-komprimiert (Compression-Framework) | m |
///
/// Nutzdaten: Knotenzahl (UInt32), Länge des Namenspuffers (UInt32), Flags
/// (UInt32, Bit 0 = vollständig), dann je Knoten 40 Byte wie `Node` (belegt,
/// logisch, Eltern, erstes Kind, Kinderzahl, Namens-Offset, Dateianzahl,
/// Namenslänge, Flags), dann der Namenspuffer. Der Kopf ist unkomprimiert,
/// damit sich Listen ohne Dekompression lesen lassen.
public enum SnapshotFile {
    public static let magic: [UInt8] = Array("DRSNAP".utf8) + [0, 0x1A]
    public static let formatVersion: UInt16 = 1
    static let nodeRecordSize = 40

    // MARK: Schreiben

    public static func encode(_ snapshot: Snapshot) throws -> Data {
        var meta = snapshot.metadata
        meta.date = normalized(meta.date)
        let header = try jsonEncoder.encode(meta)
        let payload = encodePayload(snapshot.tree)
        let compressed = try compress(payload)
        var out = Data()
        out.reserveCapacity(48 + header.count + compressed.count)
        out.append(contentsOf: magic)
        out.appendLE(formatVersion)
        out.appendLE(UInt16(0))
        out.appendLE(UInt32(header.count))
        out.append(header)
        out.appendLE(UInt64(payload.count))
        out.appendLE(UInt64(compressed.count))
        out.appendLE(fnv1a(compressed))
        out.append(compressed)
        return out
    }

    static func encodePayload(_ tree: ScanTree) -> Data {
        // Tote Knoten werden vorher entfernt (siehe SnapshotStore.condense).
        precondition(tree.deadCount == 0, "Snapshot nur von kompaktierten Bäumen")
        let count = tree.count
        var d = Data(count: 12 + count * nodeRecordSize + tree.names.count)
        d.withUnsafeMutableBytes { raw in
            func put<T: FixedWidthInteger>(_ v: T, _ off: Int) {
                raw.storeBytes(of: v.littleEndian, toByteOffset: off, as: T.self)
            }
            put(UInt32(count), 0)
            put(UInt32(tree.names.count), 4)
            put(UInt32(tree.isComplete ? 1 : 0), 8)
            var o = 12
            for n in tree.nodes {
                put(n.allocatedSize, o)
                put(n.logicalSize, o + 8)
                put(n.parent, o + 16)
                put(n.firstChild, o + 20)
                put(n.childCount, o + 24)
                put(n.nameOffset, o + 28)
                put(n.fileCount, o + 32)
                put(n.nameLength, o + 36)
                put(n.flags.subtracting(.dead).rawValue, o + 38)
                o += nodeRecordSize
            }
            tree.names.withUnsafeBytes { src in
                if let b = src.baseAddress { (raw.baseAddress! + o).copyMemory(from: b, byteCount: src.count) }
            }
        }
        return d
    }

    // MARK: Lesen

    /// Liest nur den Kopf (Metadaten), ohne die Nutzdaten zu dekomprimieren.
    public static func readMetadata(_ url: URL) throws -> SnapshotMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fixed = try handle.read(upToCount: 16) ?? Data()
        var r = Reader(fixed)
        let headerLength = try readPreamble(&r)
        guard let header = try handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength) else {
            throw SnapshotError.truncated
        }
        return try decodeHeader(header)
    }

    /// Liest Kopf und Längenangaben (ohne die Nutzdaten) und liefert die
    /// Metadaten und die Länge, die eine vollständige Datei hätte.
    public static func inspect(_ url: URL) throws -> (metadata: SnapshotMetadata, expectedLength: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fixed = try handle.read(upToCount: 16) ?? Data()
        var r = Reader(fixed)
        let headerLength = try readPreamble(&r)
        guard let header = try handle.read(upToCount: Int(headerLength)), header.count == Int(headerLength) else {
            throw SnapshotError.truncated
        }
        let metadata = try decodeHeader(header)
        guard let lengths = try handle.read(upToCount: 24), lengths.count == 24 else { throw SnapshotError.truncated }
        var l = Reader(lengths)
        let rawLength = try l.u64()
        let compressedLength = try l.u64()
        guard rawLength < 1 << 36, compressedLength < 1 << 36 else { throw SnapshotError.corrupted("length fields") }
        return (metadata, 16 + UInt64(headerLength) + 24 + compressedLength)
    }

    /// Bereich des (JSON-)Kopfs in den Dateibytes.
    static func headerRange(of data: Data) throws -> Range<Int> {
        var r = Reader(data)
        let headerLength = try readPreamble(&r)
        guard data.count >= 16 + Int(headerLength) else { throw SnapshotError.truncated }
        return 16 ..< 16 + Int(headerLength)
    }

    /// Ersetzt nur den Kopf: Längenangaben, Prüfsumme und komprimierte
    /// Nutzdaten werden unverändert übernommen (nicht dekomprimiert). Eine
    /// abgeschnittene oder zu lange Datei wird abgelehnt.
    public static func replacingHeader(in data: Data, with metadata: SnapshotMetadata) throws -> Data {
        let range = try headerRange(of: data)
        _ = try decodeHeader(data.subdata(in: range))
        var r = Reader(data.subdata(in: range.upperBound ..< data.count))
        _ = try r.u64()
        let compressedLength = try r.u64()
        _ = try r.u64()
        guard compressedLength < 1 << 36 else { throw SnapshotError.corrupted("length fields") }
        let expected = range.upperBound + 24 + Int(compressedLength)
        guard data.count >= expected else { throw SnapshotError.truncated }
        guard data.count == expected else { throw SnapshotError.corrupted("file length") }
        var meta = metadata
        meta.date = normalized(meta.date)
        let header = try jsonEncoder.encode(meta)
        guard header.count < 1 << 24 else { throw SnapshotError.corrupted("header length") }
        var out = Data()
        out.reserveCapacity(data.count - range.count + header.count)
        out.append(data.subdata(in: 0 ..< 12))
        out.appendLE(UInt32(header.count))
        out.append(header)
        out.append(data.subdata(in: range.upperBound ..< data.count))
        return out
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        var r = Reader(data)
        let headerLength = try readPreamble(&r)
        let metadata = try decodeHeader(try r.bytes(Int(headerLength)))
        let rawLength = try r.u64()
        let compressedLength = try r.u64()
        let checksum = try r.u64()
        guard rawLength < 1 << 36, compressedLength < 1 << 36 else { throw SnapshotError.corrupted("length fields") }
        let compressed = try r.bytes(Int(compressedLength))
        guard fnv1a(compressed) == checksum else { throw SnapshotError.corrupted("checksum") }
        // Längenangaben prüfen, bevor Speicher für die Nutzdaten angelegt
        // wird: Verhältnis zur komprimierten Länge und Kopf der Nutzdaten.
        guard plausibleRawLength(rawLength, compressed: compressedLength) else {
            throw SnapshotError.corrupted("length fields (ratio)")
        }
        let prefix = try decompressPrefix(compressed, count: 12)
        var pr = Reader(prefix)
        guard plausiblePayload(count: UInt64(try pr.u32()), nameLength: UInt64(try pr.u32()), rawLength: rawLength) else {
            throw SnapshotError.corrupted("length fields (payload)")
        }
        let payload = try decompress(compressed, expectedLength: Int(rawLength))
        let tree = try decodePayload(payload, rootPath: metadata.rootPath)
        return Snapshot(metadata: metadata, tree: tree)
    }

    private static func readPreamble(_ r: inout Reader) throws -> UInt32 {
        guard r.remaining >= 16 else {
            if r.remaining >= magic.count, try Array(r.peek(magic.count)) != magic { throw SnapshotError.notASnapshot }
            throw SnapshotError.truncated
        }
        guard Array(try r.bytes(magic.count)) == magic else { throw SnapshotError.notASnapshot }
        let version = try r.u16()
        _ = try r.u16()
        guard version == formatVersion else { throw SnapshotError.unsupportedVersion(version) }
        let headerLength = try r.u32()
        guard headerLength < 1 << 24 else { throw SnapshotError.corrupted("header length") }
        return headerLength
    }

    static func decodeHeader(_ data: Data) throws -> SnapshotMetadata {
        do {
            return try jsonDecoder.decode(SnapshotMetadata.self, from: data)
        } catch {
            throw SnapshotError.corrupted("header: \(error)")
        }
    }

    /// Höchstes Verhältnis unkomprimiert/komprimiert, das beim Laden
    /// akzeptiert wird. Echte Snapshots liegen bei etwa 2–5 (gemessen, siehe
    /// docs/DECISIONS.md); auch ein Baum aus lauter gleich großen Dateien mit
    /// fortlaufenden Namen bleibt weit darunter. Die Grenze verhindert, dass
    /// eine präparierte Datei mit wenigen Bytes Gigabytes anfordert.
    static let maximumCompressionRatio: UInt64 = 256
    /// Bis zu dieser Länge ist jedes Verhältnis erlaubt (winzige Bäume).
    static let ratioFreeRawLength: UInt64 = 1 << 20
    /// Namen sind höchstens 255 UTF-16-Zeichen bzw. 255 Byte (`NAME_MAX`)
    /// lang, in UTF-8 also unter 1024 Byte; im Schnitt pro Knoten kann der
    /// Namenspuffer nicht länger sein.
    static let maximumNameBytesPerNode: UInt64 = 1024

    /// Passt die angegebene unkomprimierte Länge zur komprimierten?
    static func plausibleRawLength(_ raw: UInt64, compressed: UInt64) -> Bool {
        guard compressed > 0 else { return raw == 0 }
        if raw <= ratioFreeRawLength { return true }
        return raw / compressed <= maximumCompressionRatio
    }

    /// Passen Knotenzahl und Namenslänge aus dem Kopf der Nutzdaten zur
    /// angegebenen unkomprimierten Länge?
    static func plausiblePayload(count: UInt64, nameLength: UInt64, rawLength: UInt64) -> Bool {
        guard count > 0, count < UInt64(Int32.max), nameLength <= count * maximumNameBytesPerNode else { return false }
        return rawLength == 12 + count * UInt64(nodeRecordSize) + nameLength
    }

    /// Prüft die Namen aller Knoten außer der Wurzel: nicht leer, kein „/“,
    /// kein NUL, nicht „.“ oder „..“. Solche Namen kann kein Scan erzeugen,
    /// sie würden aber Pfade (und damit Aktionen wie den Papierkorb) auf
    /// andere Orte lenken.
    static func firstInvalidName(in tree: ScanTree) -> Int32? {
        let slash = UInt8(ascii: "/"), dot = UInt8(ascii: ".")
        for i in 1 ..< Int32(tree.count) {
            let n = tree.nameBytes(of: i)
            if n.isEmpty || n.contains(slash) || n.contains(0) { return i }
            if n.count <= 2, n.allSatisfy({ $0 == dot }) { return i }
        }
        return nil
    }

    static func decodePayload(_ data: Data, rootPath: String) throws -> ScanTree {
        var r = Reader(data)
        let count = Int(try r.u32())
        let nameLength = Int(try r.u32())
        let flags = try r.u32()
        guard count > 0, count < Int(Int32.max), r.remaining == count * nodeRecordSize + nameLength else {
            throw SnapshotError.corrupted("payload size")
        }
        let nodeBytes = try r.bytes(count * nodeRecordSize)
        let nodes = nodeBytes.withUnsafeBytes { raw in
            [Node](unsafeUninitializedCapacity: count) { buf, initialized in
                func get<T: FixedWidthInteger>(_ off: Int, _: T.Type) -> T {
                    T(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: T.self))
                }
                for i in 0 ..< count {
                    let o = i * nodeRecordSize
                    buf.initializeElement(at: i, to: Node(
                        allocatedSize: get(o, UInt64.self), logicalSize: get(o + 8, UInt64.self),
                        parent: get(o + 16, Int32.self), firstChild: get(o + 20, Int32.self),
                        childCount: get(o + 24, Int32.self), nameOffset: get(o + 28, UInt32.self),
                        fileCount: get(o + 32, UInt32.self), nameLength: get(o + 36, UInt16.self),
                        flags: NodeFlags(rawValue: get(o + 38, UInt16.self)).subtracting(.dead)))
                }
                initialized = count
            }
        }
        let names = [UInt8](try r.bytes(nameLength))
        // Struktur prüfen, bevor jemand den Baum benutzt.
        for (i, n) in nodes.enumerated() {
            let ok = (i == 0 ? n.parent == -1 : (n.parent >= 0 && Int(n.parent) < i))
                && n.childCount >= 0 && (n.childCount == 0 || (Int(n.firstChild) > i
                    && Int(n.firstChild) + Int(n.childCount) <= count))
                && Int(n.nameOffset) + Int(n.nameLength) <= nameLength
            guard ok else { throw SnapshotError.corrupted("node \(i)") }
        }
        let tree = ScanTree(rootPath: rootPath, nodes: nodes, names: names, isComplete: flags & 1 != 0)
        let problems = tree.validate(limit: 1)
        guard problems.isEmpty else { throw SnapshotError.corrupted(problems[0]) }
        if let bad = firstInvalidName(in: tree) { throw SnapshotError.corrupted("name of node \(bad)") }
        return tree
    }

    // MARK: Kompression (LZFSE über das Compression-Framework)

    static func compress(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        // LZFSE vergrößert nicht komprimierbare Daten nur minimal.
        let capacity = data.count + data.count / 16 + 4096
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { throw SnapshotError.corrupted("compression failed") }
        out.count = written
        return out
    }

    /// Dekomprimiert nur die ersten `count` Bytes (für die Prüfung der
    /// Längenangaben, ohne den ganzen Puffer anzulegen).
    static func decompressPrefix(_ data: Data, count: Int) throws -> Data {
        guard !data.isEmpty else { throw SnapshotError.corrupted("empty payload") }
        var out = Data(count: count)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, count,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == count else { throw SnapshotError.corrupted("payload header") }
        return out
    }

    static func decompress(_ data: Data, expectedLength: Int) throws -> Data {
        guard expectedLength > 0 else { return Data() }
        guard !data.isEmpty else { throw SnapshotError.corrupted("empty payload") }
        // Ein Byte mehr Platz: So fällt auf, wenn die Daten länger wären.
        var out = Data(count: expectedLength + 1)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedLength + 1,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == expectedLength else {
            throw SnapshotError.corrupted("decompression yielded \(written) instead of \(expectedLength) bytes")
        }
        out.count = expectedLength
        return out
    }

    /// FNV-1a (64 Bit), schnell genug für einige 10 MB.
    static func fnv1a(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        data.withUnsafeBytes { raw in
            for b in raw.bindMemory(to: UInt8.self) {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01B3
            }
        }
        return h
    }

    /// Zeitpunkte werden auf ganze Millisekunden gespeichert.
    static func milliseconds(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func date(milliseconds ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    /// Auf Millisekunden gerundet, wie nach Speichern und Laden.
    public static func normalized(_ d: Date) -> Date { date(milliseconds: milliseconds(d)) }

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            try c.encode(milliseconds(d))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            date(milliseconds: try dec.singleValueContainer().decode(Int64.self))
        }
        return d
    }()
}

// MARK: - Hilfen für das Binärformat

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}

/// Liest little-endian-Zahlen aus `Data`; wirft `.truncated` am Ende.
struct Reader {
    let data: Data
    var pos: Int

    init(_ data: Data) {
        self.data = data
        pos = data.startIndex
    }

    var remaining: Int { data.endIndex - pos }

    func peek(_ n: Int) throws -> Data {
        guard remaining >= n else { throw SnapshotError.truncated }
        return data[pos ..< pos + n]
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw SnapshotError.truncated }
        defer { pos += n }
        return data[pos ..< pos + n]
    }

    mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw SnapshotError.truncated }
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: pos ..< pos + size)
        }
        pos += size
        return T(littleEndian: v)
    }

    mutating func u16() throws -> UInt16 { try int(UInt16.self) }
    mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    mutating func i32() throws -> Int32 { try int(Int32.self) }
    mutating func u64() throws -> UInt64 { try int(UInt64.self) }
}
