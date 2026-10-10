import Foundation

/// Verwaltung laufender Teil-Rescans (SPEC 3.8) für die Oberfläche.
///
/// Regeln:
/// - Während ein vollständiger Scan läuft, gibt es keinen Teil-Rescan (der
///   Baum ist dann nur ein vorläufiger Snapshot).
/// - Derselbe Ordner oder ein Ordner, dessen Vorfahr gerade neu eingelesen
///   wird, startet nicht ein zweites Mal (`alreadyCovered`); der laufende
///   Job wird aber als veraltet markiert und nach dem Ende neu gestartet
///   (`finish` → `.rerun`), ebenso nach einer Baumänderung darunter
///   (`noteEdit(at:)`, z. B. Papierkorb oder Zurücklegen).
/// - Ein Vorfahr laufender Rescans ersetzt diese: Sie werden abgebrochen,
///   ihre Ergebnisse verworfen (`start(cancelling:)`).
/// - Unabhängige Ordner laufen parallel. Jedes Ergebnis wird beim Eintreffen
///   in den **aktuellen** Baum eingehängt (`PartialRescan.merge`), nicht in
///   den Baum vom Start; so gehen parallele Änderungen nicht verloren.
public struct RescanQueue: Sendable, Equatable {
    public struct Job: Sendable, Equatable {
        public let id: UInt64
        public let path: String
        /// Seit dem Start kam eine abgedeckte Anfrage oder eine Baumänderung
        /// darunter: Das Ergebnis ist womöglich veraltet.
        public internal(set) var dirty = false
    }

    /// Was mit dem Ergebnis eines fertigen Jobs geschieht.
    public enum Completion: Sendable, Equatable {
        /// In den aktuellen Baum einhängen.
        case apply
        /// Abgebrochen oder ersetzt: verwerfen.
        case discard
        /// Veraltet: verwerfen und denselben Job (gleiche ID) neu starten.
        case rerun
    }

    public enum Decision: Sendable, Equatable {
        /// Starten; die genannten Jobs abbrechen (ihr Teilbaum ist enthalten).
        case start(id: UInt64, cancelling: [UInt64])
        /// Läuft schon (für denselben Ordner oder einen Vorfahren).
        case alreadyCovered(by: String)
        case blockedByFullScan
    }

    public private(set) var jobs: [Job] = []
    private var nextID: UInt64 = 1

    public init() {}

    public var isEmpty: Bool { jobs.isEmpty }
    public var paths: [String] { jobs.map(\.path) }

    public mutating func request(_ path: String, fullScanRunning: Bool) -> Decision {
        if fullScanRunning { return .blockedByFullScan }
        if let i = jobs.firstIndex(where: { Self.covers($0.path, path) }) {
            // Der laufende Job hat den Ordner womöglich schon gelesen: Er läuft
            // nach dem Ende noch einmal, statt die Anfrage zu verschlucken.
            jobs[i].dirty = true
            return .alreadyCovered(by: jobs[i].path)
        }
        let superseded = jobs.filter { Self.covers(path, $0.path) }.map(\.id)
        jobs.removeAll { superseded.contains($0.id) }
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, path: path))
        return .start(id: id, cancelling: superseded)
    }

    /// Meldet einen Job als fertig. `.discard`, wenn er inzwischen
    /// abgebrochen oder ersetzt wurde; `.rerun`, wenn er veraltet ist (er
    /// bleibt dann mit derselben ID eingetragen und ist neu zu starten).
    @discardableResult
    public mutating func finish(_ id: UInt64) -> Completion {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return .discard }
        if jobs[i].dirty {
            jobs[i].dirty = false
            return .rerun
        }
        jobs.remove(at: i)
        return .apply
    }

    /// Meldet eine Änderung des Baums (Papierkorb, Zurücklegen) bei `path`.
    /// Jobs, die `path` mit einlesen, sind danach veraltet: Ihr Ergebnis würde
    /// beim Einhängen über die Änderung geschrieben (entfernte Elemente kämen
    /// zurück, zurückgelegte fehlten). Sie laufen deshalb noch einmal.
    public mutating func noteEdit(at path: String) {
        for i in jobs.indices where Self.covers(jobs[i].path, path) { jobs[i].dirty = true }
    }

    /// Bricht alle Jobs ab (z. B. beim Start eines vollständigen Scans).
    public mutating func cancelAll() -> [UInt64] {
        defer { jobs.removeAll() }
        return jobs.map(\.id)
    }

    /// Wird `path` gerade (direkt oder über einen Vorfahren) neu eingelesen?
    public func job(covering path: String) -> Job? {
        jobs.first { Self.covers($0.path, path) }
    }

    /// `ancestor` ist `path` oder ein Vorfahr davon (Komponentengrenze).
    public static func covers(_ ancestor: String, _ path: String) -> Bool {
        if ancestor == "/" { return true }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }
}

/// Ergebnis eines eingehängten Teil-Rescans.
public struct RescanMerge: Sendable {
    public let edit: TreeEdit
    public let path: String
    public let name: String
    /// Der Ordner existierte nicht mehr und wurde entfernt.
    public let removed: Bool
    public let before: UInt64
    public let after: UInt64
    public let logicalBefore: UInt64
    public let logicalAfter: UInt64

    public var tree: ScanTree { edit.tree }

    /// Hinweis „Name: alt → neu (±Δ)“ (SPEC 3.8).
    public func summary(_ mode: SizeMode = .allocated) -> String {
        let (b, a) = mode == .allocated ? (before, after) : (logicalBefore, logicalAfter)
        return PartialRescan.summary(name: name, before: b, after: a, removed: removed)
    }
}

public enum PartialRescan {
    /// Liest `path` mit den Optionen des ursprünglichen Scans ein. `nil`, wenn
    /// der Pfad nicht mehr existiert. Ist `path` inzwischen ein Symlink, wird
    /// ihm nicht gefolgt (Ergebnis: ein Symlink-Blatt, wie im vollständigen
    /// Scan); nur für die Scan-Wurzel `followSymlink: true` übergeben.
    public static func scan(_ path: String, options: ScanOptions, followSymlink: Bool = false,
                            cancellation: ScanCancellation = ScanCancellation(),
                            onProgress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult? {
        do {
            return try ScanEngine(options: options).scanBlocking(path, followRootSymlink: followSymlink,
                                                                 cancellation: cancellation, onProgress: onProgress)
        } catch ScanError.notFound {
            return nil
        }
    }

    /// Hängt das Ergebnis eines Teilscans in den **aktuellen** Baum ein.
    /// `scanned == nil` heißt: Der Ordner existiert nicht mehr; er wird
    /// entfernt. `nil` als Rückgabe: Der Pfad steht nicht (mehr) im Baum
    /// (z. B. schon mit einem Vorfahren entfernt), oder die Wurzel selbst ist
    /// verschwunden – dann gibt es nichts einzuhängen.
    public static func merge(_ scanned: ScanTree?, path: String, into tree: ScanTree) -> RescanMerge? {
        guard let index = tree.index(ofPath: path) else { return nil }
        let node = tree.node(index)
        let name = index == ScanTree.rootIndex ? (tree.rootPath as NSString).lastPathComponent : tree.name(of: index)
        guard let scanned else {
            guard index != ScanTree.rootIndex else { return nil }
            let edit = tree.removingNode(at: index)
            return RescanMerge(edit: edit, path: path, name: name, removed: true, before: node.allocatedSize,
                               after: 0, logicalBefore: node.logicalSize, logicalAfter: 0)
        }
        let edit = tree.replacingSubtree(at: index, with: scanned)
        return RescanMerge(edit: edit, path: path, name: name, removed: false, before: edit.allocatedBefore,
                           after: edit.allocatedAfter, logicalBefore: edit.logicalBefore,
                           logicalAfter: edit.logicalAfter)
    }

    /// „Library: 182.4 GB → 176.1 GB (−6.3 GB)“; „x: no longer exists
    /// (−1.2 GB)“; ohne Änderung „x: 1.2 GB (unchanged)“.
    public static func summary(name: String, before: UInt64, after: UInt64, removed: Bool) -> String {
        if removed { return L("rescan.summary.removed", name, ByteFormat.signed(-Int64(clamping: before))) }
        if before == after { return L("rescan.summary.unchanged", name, ByteFormat.string(after)) }
        let delta = Int64(clamping: after) - Int64(clamping: before)
        return L("rescan.summary.changed", name, ByteFormat.string(before), ByteFormat.string(after), ByteFormat.signed(delta))
    }

    /// Geschätzter Fortschritt eines Teilscans aus den bisher gelesenen Bytes
    /// und der alten Größe des Ordners (höchstens 97 %, bis er fertig ist).
    /// `nil`, wenn die alte Größe 0 ist (unbestimmt).
    public static func estimatedProgress(scannedBytes: UInt64, previousSize: UInt64) -> Double? {
        guard previousSize > 0 else { return nil }
        return min(0.97, Double(scannedBytes) / Double(previousSize))
    }
}
