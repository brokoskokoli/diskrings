import Foundation
import os

/// Einstellungen für einen Scan.
public struct ScanOptions: Sendable, Equatable {
    /// Versteckte Einträge (Name mit „.“ oder `UF_HIDDEN`) mitzählen. Standard: ja.
    public var includeHidden: Bool = true
    /// Absolute Pfade, die samt Teilbaum übersprungen werden.
    public var excludedPaths: [String] = []
    /// Andere Volumes (Einhängepunkte) betreten. Standard: nein.
    /// `/System/Volumes/Data` wird auch dann nie betreten, wenn `/` gescannt
    /// wird, weil seine Inhalte schon über die Firmlinks erscheinen.
    public var crossMountPoints: Bool = false
    /// Anzahl paralleler Worker; `nil` = alle Kerne, höchstens 8 (siehe
    /// docs/DECISIONS.md). `1` ergibt einen sequenziellen Scan.
    public var workerCount: Int? = nil
    /// Abstand der Fortschrittsmeldungen und Live-Snapshots in Sekunden.
    public var progressInterval: Double = 0.25
    /// Tiefe der vorläufigen Live-Snapshots (Wurzel plus k Ebenen). Standard 6
    /// wie die Standard-Ringzahl; gemessener Aufwand in docs/PERFORMANCE.md.
    public var snapshotDepth: Int = 6
    /// Nach so vielen Einträgen gibt ein Worker offene Unterordner an die
    /// gemeinsame Queue ab, auch wenn gerade kein Worker untätig ist.
    public var splitThreshold: Int = 50_000

    public init(
        includeHidden: Bool = true,
        excludedPaths: [String] = [],
        crossMountPoints: Bool = false,
        workerCount: Int? = nil,
        progressInterval: Double = 0.25,
        snapshotDepth: Int = 6,
        splitThreshold: Int = 50_000
    ) {
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
        self.crossMountPoints = crossMountPoints
        self.workerCount = workerCount
        self.progressInterval = progressInterval
        self.snapshotDepth = snapshotDepth
        self.splitThreshold = splitThreshold
    }

    /// Tatsächlich verwendete Worker-Anzahl.
    public var effectiveWorkerCount: Int {
        if let w = workerCount { return max(1, w) }
        return min(8, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }
}

/// Zwischenstand während des Scans.
public struct ScanProgress: Sendable, Equatable {
    /// Gefundene Dateien (alles außer Ordnern).
    public var filesScanned: Int
    /// Gelesene Ordner.
    public var directoriesScanned: Int
    /// Bisher gezählte belegte Bytes (vorläufig, Hardlinks noch nicht bereinigt).
    public var allocatedBytes: UInt64
    /// Zuletzt gelesener Ordner.
    public var currentPath: String
    /// Seit Scanbeginn vergangene Zeit in Sekunden.
    public var elapsed: Double
    /// Anzahl der Worker, die gerade einen Teilbaum lesen.
    public var activeWorkers: Int = 0
    /// Herzschlag: Anzahl der bisher gelesenen `getattrlistbulk`-Blöcke. Steigt
    /// auch, während ein sehr großer Ordner gelesen wird (die Zähler oben
    /// steigen erst, wenn er fertig ist); siehe `ScanStallDetector`.
    public var heartbeat: UInt64 = 0
}

/// Ereignisse des asynchronen Scan-Streams.
public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// Vorläufiger Baum der obersten Ebenen (siehe `ScanOptions.snapshotDepth`).
    /// Ordnergrößen enthalten die bisher gefundenen Dateien; einzelne Dateien
    /// erscheinen darin noch nicht als eigene Knoten.
    case snapshot(ScanTree)
    case finished(ScanResult)
}

/// Endergebnis eines Scans.
public struct ScanResult: Sendable {
    public let tree: ScanTree
    /// Dauer in Sekunden.
    public let duration: Double
    public let fileCount: Int
    public let directoryCount: Int
    /// Ordner, die nicht gelesen werden konnten.
    public let unreadablePaths: [String]
    /// Einhängepunkte, die nicht betreten wurden.
    public let skippedMountPoints: [String]
    /// Anzahl der Hardlinks, die nicht erneut gezählt wurden.
    public let hardlinkDuplicates: Int
    public let options: ScanOptions

    public var allocatedSize: UInt64 { tree.root.allocatedSize }
    public var logicalSize: UInt64 { tree.root.logicalSize }
}

public enum ScanError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    /// Teil-Rescan ohne Wurzel-Symlink: Ein Vorfahr des Pfads ist kein echter
    /// Ordner mehr (Symlink, Datei oder verschwunden). Es wurde nichts
    /// gelesen; neu einzulesen ist `ancestor`.
    case ancestorChanged(String, ancestor: String)
    case tooManyNodes

    public var description: String {
        switch self {
        case .notFound(let p): L("error.scan.notFound", p)
        case .ancestorChanged(_, let a): L("error.scan.ancestorChanged", a)
        case .tooManyNodes: L("error.scan.tooManyNodes")
        }
    }
}

/// Abbruch-Signal, das die Worker pro Ordner prüfen.
public final class ScanCancellation: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func cancel() { flag.withLock { $0 = true } }
    public var isCancelled: Bool { flag.withLock { $0 } }
}

public enum SystemInfo {
    /// Anzahl der Performance-Kerne (`hw.perflevel0.physicalcpu`), sonst aller Kerne.
    public static var performanceCoreCount: Int {
        if let v = sysctlInt("hw.perflevel0.physicalcpu"), v > 0 { return v }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
