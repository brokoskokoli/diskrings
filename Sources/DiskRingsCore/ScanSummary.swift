import Foundation

/// Kennzahlen eines abgeschlossenen Scans **ohne** den Baum (Zusammenfassung
/// nach SPEC 3.2, Statusleiste, Snapshot-Metadaten). Die App hält davon nur
/// eine Version neben dem aktuellen Baum; ein `ScanResult` würde den
/// ursprünglichen Baum nach Papierkorb oder Teil-Rescan weiter festhalten.
public struct ScanSummary: Sendable, Equatable {
    public let rootPath: String
    /// Dauer des Scans in Sekunden.
    public let duration: Double
    public let options: ScanOptions
    public let skippedMountPoints: [String]
    public let hardlinkDuplicates: Int
    // Diese Werte folgen dem aktuellen Baum (`updated(for:)`).
    public private(set) var fileCount: Int
    public private(set) var directoryCount: Int
    public private(set) var allocatedSize: UInt64
    public private(set) var logicalSize: UInt64
    /// Nicht lesbare Ordner, die noch im Baum sind.
    public private(set) var unreadablePaths: [String]

    public init(_ r: ScanResult) {
        rootPath = r.tree.rootPath
        duration = r.duration
        options = r.options
        skippedMountPoints = r.skippedMountPoints
        hardlinkDuplicates = r.hardlinkDuplicates
        fileCount = r.fileCount
        directoryCount = r.directoryCount
        allocatedSize = r.allocatedSize
        logicalSize = r.logicalSize
        unreadablePaths = r.unreadablePaths
    }

    /// Zahlen passend zu einer neuen Baumversion (nach Papierkorb, Undo,
    /// Teil-Rescan): Dateien, Ordner und Größen aus dem Baum (wie bei
    /// `ScanEngine`); nicht lesbare Ordner ohne die entfernten, plus die im
    /// neuen Baum als unlesbar markierten (z. B. nach einem Teil-Rescan).
    public func updated(for tree: ScanTree) -> ScanSummary {
        var s = self
        s.fileCount = tree.root.fileCount
        s.directoryCount = tree.directoryCount
        s.allocatedSize = tree.root.allocatedSize
        s.logicalSize = tree.root.logicalSize
        var paths = Set(unreadablePaths.filter { tree.index(ofPath: $0) != nil })
        paths.formUnion(tree.paths(withFlag: .unreadable))
        s.unreadablePaths = paths.sorted()
        return s
    }
}

extension SnapshotMetadata {
    /// Metadaten für den aktuellen Baum eines Scans (der sich seit dem Scan
    /// durch Papierkorb oder Teil-Rescan geändert haben kann).
    public static func current(for summary: ScanSummary, tree: ScanTree, volume: VolumeInfo? = nil,
                               name: String? = nil, date: Date = Date()) -> SnapshotMetadata {
        let v = volume ?? VolumeInfo.forPath(tree.rootPath)
        return SnapshotMetadata(
            name: name, date: date, rootPath: tree.rootPath, volumeUUID: v?.uuid,
            volume: v.map { VolumeMetrics($0, scanRoot: tree.rootPath, scanTotal: tree.root.allocatedSize) },
            options: SnapshotScanOptions(summary.options), minimumFileSize: 0,
            allocatedSize: tree.root.allocatedSize, logicalSize: tree.root.logicalSize,
            fileCount: UInt64(tree.root.fileCount), nodeCount: tree.liveCount)
    }
}
