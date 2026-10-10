import Darwin
import Foundation

/// Ergebnis eines Teil-Rescans (SPEC 3.8).
public struct RescanResult: Sendable {
    /// Neue Baum-Version samt Index-Übersetzung (siehe `TreeEdit`).
    public let edit: TreeEdit
    /// Neu eingelesener Pfad.
    public let path: String
    /// `true`, wenn der Pfad nicht mehr existierte und der Knoten deshalb
    /// entfernt wurde (`edit.index` ist dann der Elternknoten).
    public let removed: Bool
    /// Nicht lesbare Ordner innerhalb des neu eingelesenen Teilbaums.
    public let unreadablePaths: [String]
    /// Dauer des Teilscans in Sekunden (ohne das Einhängen in den Baum).
    public let scanDuration: Double
    /// Dauer des Einhängens in den Baum in Sekunden.
    public let mergeDuration: Double

    public var tree: ScanTree { edit.tree }
}

extension ScanEngine {
    /// Liest den Teilbaum unter `index` neu ein und hängt ihn in eine neue
    /// Version von `tree` ein (der alte Baum bleibt unverändert). Existiert
    /// der Pfad nicht mehr, wird der Knoten entfernt. Ein nicht betretener
    /// Einhängepunkt wird nur mit `crossMountPoints` neu eingelesen.
    public func rescanBlocking(
        subtree index: Int32, in tree: ScanTree, cancellation: ScanCancellation = ScanCancellation()
    ) throws -> RescanResult {
        precondition(Int(index) < tree.count && !tree.nodes[Int(index)].flags.contains(.dead),
                     "node \(index) is not live")
        let path = tree.path(of: index)
        let node = tree.nodes[Int(index)]
        let start = DispatchTime.now().uptimeNanoseconds
        func seconds(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9 }

        if node.flags.contains(.mountPoint), !options.crossMountPoints {
            let edit = TreeEdit(tree: tree, index: index, allocatedBefore: node.allocatedSize,
                                allocatedAfter: node.allocatedSize, logicalBefore: node.logicalSize,
                                logicalAfter: node.logicalSize, compacted: false, relocations: [:], compactionMap: nil)
            return RescanResult(edit: edit, path: path, removed: false, unreadablePaths: [], scanDuration: 0,
                                mergeDuration: 0)
        }

        let sub: ScanResult
        do {
            // Nur der Wurzel folgen; ein inzwischen durch einen Symlink ersetzter
            // Ordner wird wie im vollständigen Scan ein Symlink-Blatt.
            sub = try scanBlocking(path, followRootSymlink: index == ScanTree.rootIndex, cancellation: cancellation)
        } catch ScanError.notFound where index != ScanTree.rootIndex {
            let scanTime = seconds(since: start)
            let t = DispatchTime.now().uptimeNanoseconds
            let edit = tree.removingNode(at: index)
            return RescanResult(edit: edit, path: path, removed: true, unreadablePaths: [], scanDuration: scanTime,
                                mergeDuration: seconds(since: t))
        }
        let scanTime = seconds(since: start)
        let t = DispatchTime.now().uptimeNanoseconds
        let edit = tree.replacingSubtree(at: index, with: sub.tree)
        return RescanResult(edit: edit, path: path, removed: false, unreadablePaths: sub.unreadablePaths,
                            scanDuration: scanTime, mergeDuration: seconds(since: t))
    }

    /// Wie `rescanBlocking(subtree:in:)`, aber asynchron auf einem eigenen
    /// Thread; ein Abbruch der Task bricht den Teilscan ab.
    public func rescan(subtree index: Int32, in tree: ScanTree) async throws -> RescanResult {
        let token = ScanCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RescanResult, Error>) in
                let thread = Thread {
                    do {
                        cont.resume(returning: try self.rescanBlocking(subtree: index, in: tree, cancellation: token))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                thread.qualityOfService = .userInitiated
                thread.name = "DiskRings.Rescan"
                thread.start()
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Liest `path` neu ein. Steht der Pfad (noch) nicht im Baum, wird der
    /// nächste vorhandene Vorfahre neu eingelesen, z. B. der Elternordner
    /// nach einem Undo des Papierkorbs (SPEC 3.6).
    public func rescanBlocking(
        path: String, in tree: ScanTree, cancellation: ScanCancellation = ScanCancellation()
    ) throws -> RescanResult {
        let index = Self.nearestExistingIndex(of: path, in: tree)
        return try rescanBlocking(subtree: index, in: tree, cancellation: cancellation)
    }

    /// Index des Knotens für `path` oder seines nächsten Vorfahren im Baum.
    public static func nearestExistingIndex(of path: String, in tree: ScanTree) -> Int32 {
        var p = path
        while true {
            if let i = tree.index(ofPath: p) { return i }
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p || parent.isEmpty { return ScanTree.rootIndex }
            p = parent
        }
    }
}
