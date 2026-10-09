import Darwin
import Foundation

/// Eine gespeicherte Snapshot-Datei (aus der Liste, ohne geladenen Baum).
public struct SnapshotInfo: Sendable, Equatable, Identifiable {
    public let url: URL
    public let metadata: SnapshotMetadata
    /// Dateigröße in Byte.
    public let fileSize: UInt64

    public var id: UUID { metadata.id }
}

/// Eine Datei in der Ablage, die sich nicht als Snapshot lesen lässt
/// (abgeschnitten, beschädigter Kopf, kein Snapshot). Sie lässt sich nur
/// löschen; `prune` räumt sie auf.
public struct DamagedSnapshot: Sendable, Equatable, Identifiable {
    public let url: URL
    public let fileSize: UInt64
    /// Grund, z. B. „Snapshot-Datei ist unvollständig“.
    public let reason: String
    /// Metadaten, falls wenigstens der Kopf lesbar ist.
    public let metadata: SnapshotMetadata?

    public init(url: URL, fileSize: UInt64, reason: String, metadata: SnapshotMetadata?) {
        self.url = url
        self.fileSize = fileSize
        self.reason = reason
        self.metadata = metadata
    }

    public var id: String { url.path }
}

/// Ablage der Snapshots unter
/// `~/Library/Application Support/DiskRings/Snapshots/<volume-uuid>/<zeitstempel>.drsnap`
/// (SPEC 3.9). Das Basisverzeichnis ist für Tests injizierbar.
public struct SnapshotStore: Sendable {
    public let baseDirectory: URL
    /// Dateien unter dieser belegten Größe werden nicht als eigene Knoten
    /// gespeichert, sondern nur in die Ordnersumme gerechnet. Standard 1 MB.
    public var minimumFileSize: UInt64

    public static let defaultMinimumFileSize: UInt64 = 1_000_000
    /// Standard für die maximale Anzahl Snapshots pro Scan-Wurzel (SPEC 3.7).
    public static let defaultMaxCount = 20

    public init(baseDirectory: URL = SnapshotStore.defaultBaseDirectory,
                minimumFileSize: UInt64 = SnapshotStore.defaultMinimumFileSize) {
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.minimumFileSize = minimumFileSize
    }

    /// `~/Library/Application Support/DiskRings/Snapshots`
    public static var defaultBaseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("DiskRings/Snapshots", isDirectory: true)
    }

    // MARK: Speichern

    /// Speichert einen Scan als Snapshot. Ohne `volume` wird das Volume der
    /// Scan-Wurzel abgefragt.
    @discardableResult
    public func save(_ result: ScanResult, volume: VolumeInfo? = nil, name: String? = nil,
                     date: Date = Date()) throws -> SnapshotInfo {
        try save(result.tree, metadata: .current(for: result, volume: volume, name: name, date: date))
    }

    /// Speichert `tree` mit den gegebenen Metadaten. Kleine Dateien werden
    /// dabei nach `minimumFileSize` herausgefiltert; `minimumFileSize`,
    /// Kennzahlen und Knotenzahl in den Metadaten werden passend gesetzt.
    @discardableResult
    public func save(_ tree: ScanTree, metadata: SnapshotMetadata) throws -> SnapshotInfo {
        let condensed = Self.condense(tree, minimumFileSize: minimumFileSize)
        var meta = metadata
        meta.minimumFileSize = minimumFileSize
        meta.date = SnapshotFile.normalized(meta.date)
        meta.rootPath = tree.rootPath
        meta.allocatedSize = condensed.root.allocatedSize
        meta.logicalSize = condensed.root.logicalSize
        meta.fileCount = UInt64(condensed.root.fileCount)
        meta.nodeCount = condensed.count
        let data = try SnapshotFile.encode(Snapshot(metadata: meta, tree: condensed))
        let dir = baseDirectory.appendingPathComponent(Self.directoryName(for: meta.volumeUUID), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Erst vollständig in eine temporäre Datei schreiben, dann ohne
        // Überschreiben umbenennen: Eine halb geschriebene `.drsnap` gäbe es
        // sonst kurz in der Ablage, und ein gleichzeitiges `prune` hielte sie
        // für beschädigt.
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        for _ in 0 ..< 100 {
            let url = Self.uniqueURL(in: dir, date: meta.date)
            if renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 {
                return SnapshotInfo(url: url, metadata: meta, fileSize: UInt64(data.count))
            }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Kompakter Baum ohne tote Knoten und ohne Dateien unter `minimumFileSize`
    /// (belegte Größe). Ordner behalten ihre Größe und Dateianzahl, kleine
    /// Dateien stecken also weiter in der Ordnersumme. Die Reihenfolge der
    /// Kinder bleibt erhalten.
    public static func condense(_ tree: ScanTree, minimumFileSize: UInt64) -> ScanTree {
        let nodes = tree.nodes
        var order: [Int32] = [0]
        var kept: [Int32] = [] // pro neuem Knoten: Anzahl behaltener Kinder
        order.reserveCapacity(tree.liveCount)
        var dropped = false
        var k = 0
        while k < order.count {
            let n = nodes[Int(order[k])]
            var c = 0
            for ch in n.firstChild ..< n.firstChild + n.childCount {
                let child = nodes[Int(ch)]
                if !child.isDirectory, child.allocatedSize < minimumFileSize {
                    dropped = true
                    continue
                }
                order.append(ch)
                c += 1
            }
            kept.append(Int32(c))
            k += 1
        }
        var map = [Int32](repeating: -1, count: nodes.count)
        for (newIdx, old) in order.enumerated() { map[Int(old)] = Int32(newIdx) }
        var newNodes: [Node] = []
        newNodes.reserveCapacity(order.count)
        var names: [UInt8] = []
        var firstChild: Int32 = 1
        for (newIdx, old) in order.enumerated() {
            var n = nodes[Int(old)]
            n.parent = newIdx == 0 ? -1 : map[Int(n.parent)]
            let off = Int(n.nameOffset)
            n.nameOffset = UInt32(names.count)
            names.append(contentsOf: tree.names[off ..< off + Int(n.nameLength)])
            n.childCount = kept[newIdx]
            n.firstChild = firstChild
            firstChild += n.childCount
            newNodes.append(n)
        }
        return ScanTree(rootPath: tree.rootPath, nodes: newNodes, names: names,
                        isComplete: tree.isComplete && !dropped)
    }

    // MARK: Verwalten

    /// Alle lesbaren Snapshots, neueste zuerst. Beschädigte Dateien fehlen
    /// hier (siehe `listDamaged`).
    public func list() throws -> [SnapshotInfo] { try listAll().valid }

    /// Dateien in der Ablage, die sich nicht als Snapshot lesen lassen.
    public func listDamaged() throws -> [DamagedSnapshot] { try listAll().damaged }

    /// Liest alle `.drsnap`-Dateien und teilt sie in lesbare und beschädigte.
    /// Geprüft werden Vorspann, Kopf und die Dateilänge laut Längenangabe
    /// (eine abgeschnittene Datei fällt damit auf, ohne die Nutzdaten zu
    /// lesen). Die Prüfsumme wird erst beim Laden geprüft.
    public func listAll() throws -> (valid: [SnapshotInfo], damaged: [DamagedSnapshot]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return ([], []) }
        var valid: [SnapshotInfo] = []
        var damaged: [DamagedSnapshot] = []
        for dir in try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            where file.pathExtension == "drsnap" {
                let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                do {
                    let (meta, expected) = try SnapshotFile.inspect(file)
                    if size == expected {
                        valid.append(SnapshotInfo(url: file, metadata: meta, fileSize: size))
                    } else {
                        let reason = size < expected ? SnapshotError.truncated.description
                            : SnapshotError.corrupted("Dateilänge").description
                        damaged.append(DamagedSnapshot(url: file, fileSize: size, reason: reason, metadata: meta))
                    }
                } catch {
                    let reason = (error as? SnapshotError)?.description ?? "\(error)"
                    let meta = try? SnapshotFile.readMetadata(file)
                    damaged.append(DamagedSnapshot(url: file, fileSize: size, reason: reason, metadata: meta))
                }
            }
        }
        valid.sort { $0.metadata.date != $1.metadata.date ? $0.metadata.date > $1.metadata.date
            : $0.url.path > $1.url.path }
        damaged.sort { $0.url.path < $1.url.path }
        return (valid, damaged)
    }

    /// Snapshots derselben Scan-Wurzel (und, falls angegeben, desselben Volumes).
    public func list(rootPath: String, volumeUUID: String? = nil) throws -> [SnapshotInfo] {
        try list().filter { $0.metadata.rootPath == rootPath && (volumeUUID == nil || $0.metadata.volumeUUID == volumeUUID) }
    }

    public func load(_ info: SnapshotInfo) throws -> Snapshot { try load(url: info.url) }

    public func load(url: URL) throws -> Snapshot {
        try SnapshotFile.decode(try Data(contentsOf: url))
    }

    /// Löscht die Snapshot-Datei (nur innerhalb des Basisverzeichnisses).
    public func delete(_ info: SnapshotInfo) throws {
        let url = try checkedURL(info.url)
        try FileManager.default.removeItem(at: url)
    }

    /// Löscht eine beschädigte Datei (nur innerhalb des Basisverzeichnisses).
    public func delete(_ damaged: DamagedSnapshot) throws {
        let url = try checkedURL(damaged.url)
        try FileManager.default.removeItem(at: url)
    }

    /// Gibt dem Snapshot einen neuen Namen (`nil` entfernt ihn). Nur der Kopf
    /// wird neu geschrieben; die komprimierten Nutzdaten werden unverändert
    /// kopiert, nicht dekomprimiert (`SnapshotFile.replacingHeader`). Die
    /// Datei wird atomar ersetzt; eine abgeschnittene Datei bleibt unverändert.
    @discardableResult
    public func rename(_ info: SnapshotInfo, to name: String?) throws -> SnapshotInfo {
        let url = try checkedURL(info.url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let range = try SnapshotFile.headerRange(of: data)
        var meta = try SnapshotFile.decodeHeader(data.subdata(in: range))
        meta.name = name
        let newData = try SnapshotFile.replacingHeader(in: data, with: meta)
        try newData.write(to: url, options: .atomic)
        return SnapshotInfo(url: url, metadata: meta, fileSize: UInt64(newData.count))
    }

    /// Löscht die ältesten Snapshots der Scan-Wurzel, bis höchstens
    /// `maxCount` übrig sind. Gibt die gelöschten zurück.
    ///
    /// Außerdem werden beschädigte Dateien aufgeräumt: solche derselben
    /// Scan-Wurzel (Kopf lesbar) und solche ohne lesbaren Kopf (im Ordner des
    /// Volumes bzw. ohne `volumeUUID` überall). Sie stehen nicht in der
    /// Rückgabe, weil sie keine `SnapshotInfo` haben.
    @discardableResult
    public func prune(maxCount: Int = SnapshotStore.defaultMaxCount, rootPath: String,
                      volumeUUID: String? = nil) throws -> [SnapshotInfo] {
        let (valid, damaged) = try listAll()
        for d in damaged where isPrunable(d, rootPath: rootPath, volumeUUID: volumeUUID) {
            try? delete(d)
        }
        let all = valid.filter { // neueste zuerst
            $0.metadata.rootPath == rootPath && (volumeUUID == nil || $0.metadata.volumeUUID == volumeUUID)
        }
        guard all.count > maxCount else { return [] }
        let doomed = Array(all.dropFirst(max(maxCount, 0)))
        for info in doomed { try delete(info) }
        return doomed
    }

    private func isPrunable(_ d: DamagedSnapshot, rootPath: String, volumeUUID: String?) -> Bool {
        if let m = d.metadata {
            return m.rootPath == rootPath && (volumeUUID == nil || m.volumeUUID == volumeUUID)
        }
        guard volumeUUID != nil else { return true }
        return d.url.deletingLastPathComponent().lastPathComponent == Self.directoryName(for: volumeUUID)
    }

    // MARK: Hilfen

    private func checkedURL(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = baseDirectory.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/"), url.pathExtension == "drsnap" else {
            throw SnapshotError.outsideStore(url.path)
        }
        return url
    }

    static func directoryName(for volumeUUID: String?) -> String {
        guard let u = volumeUUID, !u.isEmpty, !u.contains("/") else { return "unbekannt" }
        return u
    }

    /// `<zeitstempel>.drsnap` in UTC, bei Kollision mit Zähler.
    static func uniqueURL(in dir: URL, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let stamp = f.string(from: date)
        var url = dir.appendingPathComponent("\(stamp).drsnap")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stamp)-\(n).drsnap")
            n += 1
        }
        return url
    }
}
