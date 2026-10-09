import Darwin
import Foundation

// MARK: Dateisystem-Zugriff (austauschbar für Tests)

/// Die Dateioperationen, die Papierkorb und Undo brauchen. `FileManager`
/// erfüllt das Protokoll; Tests können einen eigenen Papierkorb in einem
/// temporären Verzeichnis unterschieben.
public protocol FileTrashing {
    /// Verschiebt das Element in den Papierkorb und liefert seinen neuen Ort
    /// (`FileManager.trashItem(at:resultingItemURL:)`).
    func trashItem(at url: URL) throws -> URL?
    func moveItem(at src: URL, to dst: URL) throws
    /// Existiert der Pfad (ohne einem Symlink am Ende zu folgen)?
    func itemExists(atPath path: String) -> Bool
    /// Identität des Elements (ohne einem Symlink am Ende zu folgen);
    /// `nil`, wenn es nicht existiert.
    func identity(atPath path: String) -> FileIdentity?
    /// Pfad mit allen Symlinks aufgelöst (`realpath`); `nil`, wenn er nicht existiert.
    func resolvedPath(_ path: String) -> String?
}

extension FileTrashing {
    public func identity(atPath path: String) -> FileIdentity? { FileIdentity(path: path) }

    public func resolvedPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}

/// Woran sich ein Element im Papierkorb wiedererkennen lässt (für ⌘Z):
/// Gerät und Inode (entspricht `volumeIdentifier` plus
/// `fileResourceIdentifier`), Art, bei Dateien zusätzlich Größe und
/// Änderungsdatum. Das Verschieben in den Papierkorb (gleiches Volume, nur
/// umbenannt) ändert keinen dieser Werte. Bei Ordnern bleiben Größe und
/// Änderungsdatum außen vor, weil der Finder darin z. B. `.DS_Store` anlegt.
public struct FileIdentity: Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
    public var isDirectory: Bool
    /// Nur bei Dateien (und Symlinks).
    public var size: UInt64?
    /// Änderungsdatum in Nanosekunden seit 1970; nur bei Dateien (und Symlinks).
    public var modificationNanos: Int64?

    public init(device: UInt64, inode: UInt64, isDirectory: Bool, size: UInt64? = nil, modificationNanos: Int64? = nil) {
        self.device = device
        self.inode = inode
        self.isDirectory = isDirectory
        self.size = size
        self.modificationNanos = modificationNanos
    }

    /// Per `lstat`; `nil`, wenn der Pfad nicht existiert.
    public init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        self.init(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino), isDirectory: isDir,
                  size: isDir ? nil : UInt64(max(st.st_size, 0)),
                  modificationNanos: isDir ? nil : Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                      + Int64(st.st_mtimespec.tv_nsec))
    }
}

extension FileManager: FileTrashing {
    public func trashItem(at url: URL) throws -> URL? {
        var result: NSURL?
        try trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func itemExists(atPath path: String) -> Bool {
        (try? attributesOfItem(atPath: path)) != nil
    }
}

// MARK: Plan und Bestätigung

/// Ein Element, das in den Papierkorb soll.
public struct TrashItem: Sendable, Equatable {
    public var node: Int32
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var allocatedSize: UInt64
    public var logicalSize: UInt64
    /// Anzahl der Dateien (bei einer Datei 1).
    public var fileCount: Int

    public init(node: Int32, path: String, name: String, isDirectory: Bool, allocatedSize: UInt64,
                logicalSize: UInt64, fileCount: Int) {
        self.node = node
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
    }

    /// Größe für die Schwelle „Nicht mehr fragen“: die größere der beiden.
    var limitSize: UInt64 { max(allocatedSize, logicalSize) }
}

/// Warum aus einer Auswahl kein Papierkorb-Plan entsteht.
public enum TrashPlanError: Error, Sendable, Equatable {
    case empty
    case scanRoot(String)
    case protected(path: String, reason: ProtectedPaths.Reason)
    case notLive

    public var message: String {
        switch self {
        case .empty: L("reason.nothingSelected")
        case .scanRoot: L("trash.error.scanRoot")
        case .protected(let p, let r):
            p.isEmpty ? L("trash.error.protected", r.message)
                : L("trash.error.protectedItem", r.message, (p as NSString).lastPathComponent)
        case .notLive: L("reason.notInTree")
        }
    }
}

/// Was in den Papierkorb soll, mit Summen für den Bestätigungsdialog
/// (SPEC 3.6). Enthält nur die obersten Knoten der Auswahl.
public struct TrashPlan: Sendable, Equatable {
    public var items: [TrashItem]
    public var sizeMode: SizeMode
    /// Scan-Wurzel des Baums, aus dem der Plan stammt. `TrashService` prüft
    /// vor dem Verschieben, dass der aufgelöste Pfad noch darunter liegt.
    public var rootPath: String?

    public init(items: [TrashItem], sizeMode: SizeMode = .allocated, rootPath: String? = nil) {
        self.items = items
        self.sizeMode = sizeMode
        self.rootPath = rootPath
    }

    /// Prüft Auswahl, Scan-Wurzel und Schutzliste und baut den Plan.
    public static func make(targets: [Int32], in tree: ScanTree, protection: ProtectedPaths,
                            sizeMode: SizeMode = .allocated) -> Result<TrashPlan, TrashPlanError> {
        guard !targets.isEmpty else { return .failure(.empty) }
        for t in targets where Int(t) >= tree.count || t < 0 || tree.nodes[Int(t)].flags.contains(.dead) {
            return .failure(.notLive)
        }
        let top = NodeSelection(targets).topLevel(in: tree)
        var items: [TrashItem] = []
        for n in top {
            let path = tree.path(of: n)
            if n == ScanTree.rootIndex { return .failure(.scanRoot(path)) }
            if let r = protection.reason(for: path) { return .failure(.protected(path: path, reason: r)) }
            let node = tree.node(n)
            items.append(TrashItem(node: n, path: path, name: tree.name(of: n), isDirectory: node.isDirectory,
                                   allocatedSize: node.allocatedSize, logicalSize: node.logicalSize,
                                   fileCount: node.isDirectory ? Int(node.fileCount) : 1))
        }
        return .success(TrashPlan(items: items, sizeMode: sizeMode, rootPath: tree.rootPath))
    }

    public var totalSize: UInt64 {
        items.reduce(0) { $0 + (sizeMode == .allocated ? $1.allocatedSize : $1.logicalSize) }
    }
    public var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
    var limitSize: UInt64 { items.reduce(0) { $0 + $1.limitSize } }

    /// „Nicht mehr fragen“ ist nur unter 1 GB zulässig.
    public var allowsDontAskAgain: Bool { limitSize < TrashConfirmation.dontAskLimit }

    /// Überschrift des Bestätigungsdialogs.
    public var title: String {
        if items.count == 1 { return L("trash.confirm.title.one", items[0].name) }
        return L("trash.confirm.title.count", items.count, ByteFormat.count(items.count))
    }

    /// Text des Bestätigungsdialogs: Name, Größe und Dateianzahl bzw. Summe.
    public var message: String {
        let files = L10n.files(totalFiles)
        if items.count == 1 {
            let i = items[0]
            if !i.isDirectory { return "\(i.name) · \(ByteFormat.string(totalSize))\n\(i.path)" }
            return "\(i.name) · \(ByteFormat.string(totalSize)) · \(files)\n\(i.path)"
        }
        let names = items.prefix(5).map(\.name).joined(separator: ", ") + (items.count > 5 ? ", …" : "")
        return L("trash.confirm.total", ByteFormat.string(totalSize), files) + "\n" + names
    }
}

/// Regeln für den Bestätigungsdialog (SPEC 3.6).
public enum TrashConfirmation {
    /// „Nicht mehr fragen“ gilt nur für Elemente unter 1 GB (dezimal, wie
    /// die Anzeige).
    public static let dontAskLimit: UInt64 = 1_000_000_000

    /// Muss vor dem Papierkorb gefragt werden? Ohne Rückfrage nur, wenn der
    /// Nutzer „Nicht mehr fragen“ gewählt hat und die Summe unter 1 GB liegt.
    public static func needsConfirmation(_ plan: TrashPlan, dontAskAgain: Bool) -> Bool {
        !(dontAskAgain && plan.allowsDontAskAgain)
    }
}

// MARK: Ausführung und Undo

/// Ein Element, das im Papierkorb gelandet ist (für ⌘Z).
public struct TrashRecord: Sendable, Equatable {
    public var originalPath: String
    /// Ort im Papierkorb (`resultingItemURL`); `nil`, wenn das System ihn
    /// nicht gemeldet hat (dann ist kein Undo möglich).
    public var trashURL: URL?
    public var name: String
    public var allocatedSize: UInt64
    /// Identität beim Verschieben; ⌘Z legt nur ein Element mit derselben
    /// Identität zurück (`nil` → kein Undo).
    public var identity: FileIdentity?

    public init(originalPath: String, trashURL: URL?, name: String, allocatedSize: UInt64,
                identity: FileIdentity? = nil) {
        self.originalPath = originalPath
        self.trashURL = trashURL
        self.name = name
        self.allocatedSize = allocatedSize
        self.identity = identity
    }
}

public struct TrashFailure: Sendable, Equatable {
    public var path: String
    public var message: String
}

/// Ergebnis von `TrashService.trash`.
public struct TrashOutcome: Sendable, Equatable {
    /// Erfolgreich verschoben.
    public var trashed: [TrashRecord] = []
    /// Schon vorher nicht mehr vorhanden (der Knoten kann trotzdem aus dem
    /// Baum entfernt werden).
    public var missing: [String] = []
    public var failures: [TrashFailure] = []

    /// Pfade, deren Knoten aus dem Baum entfernt werden sollen.
    public var removedPaths: [String] { trashed.map(\.originalPath) + missing }
    public var removedSize: UInt64 { trashed.reduce(0) { $0 + $1.allocatedSize } }
}

/// Ergebnis von `TrashService.restore`.
public struct RestoreOutcome: Sendable, Equatable {
    public var restored: [String] = []
    public var failures: [TrashFailure] = []
}

/// Papierkorb und Undo (SPEC 3.6). Gelöscht wird ausschließlich über
/// `trashItem` (es gibt kein endgültiges Löschen); die Schutzliste wird hier
/// ein zweites Mal geprüft, unabhängig von Menü und Tastenkürzel.
public struct TrashService {
    public let fileManager: any FileTrashing
    public let protection: ProtectedPaths

    public init(fileManager: any FileTrashing = FileManager.default, protection: ProtectedPaths = ProtectedPaths()) {
        self.fileManager = fileManager
        self.protection = protection
    }

    public func trash(_ plan: TrashPlan) -> TrashOutcome {
        var out = TrashOutcome()
        for item in plan.items {
            if let r = protection.reason(for: item.path) {
                out.failures.append(TrashFailure(path: item.path, message: L("trash.error.protected", r.message)))
                continue
            }
            guard fileManager.itemExists(atPath: item.path) else {
                out.missing.append(item.path)
                continue
            }
            if let problem = checkResolved(item.path, rootPath: plan.rootPath) {
                out.failures.append(TrashFailure(path: item.path, message: problem))
                continue
            }
            let identity = fileManager.identity(atPath: item.path)
            do {
                let url = try fileManager.trashItem(at: URL(fileURLWithPath: item.path))
                out.trashed.append(TrashRecord(originalPath: item.path, trashURL: url, name: item.name,
                                               allocatedSize: item.allocatedSize, identity: identity))
            } catch {
                out.failures.append(TrashFailure(path: item.path, message: Self.describe(error)))
            }
        }
        return out
    }

    /// Prüft den Pfad mit aufgelöster Elternkette erneut: Ein inzwischen
    /// durch einen Symlink ersetzter Elternordner könnte sonst ein Element
    /// außerhalb der Scan-Wurzel oder in einem geschützten Bereich treffen.
    /// Der Scanner folgt keinen Symlinks; unterhalb der Wurzel muss der
    /// aufgelöste Pfad deshalb genau der aufgelösten Wurzel plus dem
    /// relativen Pfad entsprechen. Gibt die Fehlermeldung zurück oder `nil`.
    func checkResolved(_ path: String, rootPath: String?) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let resolvedParent = fileManager.resolvedPath(parent) else {
            return L("trash.error.unresolvable")
        }
        let resolved = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        if let r = protection.reason(for: resolved) {
            return L("trash.error.protectedResolved", r.message, resolved)
        }
        guard let rootPath else { return nil }
        let rootKey = ProtectedPaths.normalize(rootPath)
        let pathKey = ProtectedPaths.normalize(path)
        guard ProtectedPaths.isStrictDescendant(pathKey, of: rootKey),
              let resolvedRoot = fileManager.resolvedPath(rootPath) else {
            return L("trash.error.outsideRoot")
        }
        let relative = pathKey.dropFirst(rootKey == "/" ? 0 : rootKey.count)
        let base = ProtectedPaths.normalize(resolvedRoot)
        let expected = base == "/" ? String(relative) : base + relative
        guard ProtectedPaths.normalize(resolved) == ProtectedPaths.key(expected) else {
            return L("trash.error.outsideRootSymlink")
        }
        return nil
    }

    /// Legt Elemente aus dem Papierkorb an ihren alten Ort zurück. Ein
    /// inzwischen wieder belegter Ort wird nie überschrieben, und
    /// zurückgelegt wird nur genau das Element, das verschoben wurde (gleiche
    /// `FileIdentity`); liegt unter der Papierkorb-Adresse inzwischen etwas
    /// anderes (Papierkorb geleert, neues Element gleichen Namens), bleibt es
    /// dort.
    public func restore(_ records: [TrashRecord]) -> RestoreOutcome {
        var out = RestoreOutcome()
        for r in records {
            guard let src = r.trashURL else {
                out.failures.append(TrashFailure(path: r.originalPath, message: L("trash.undo.unknownLocation")))
                continue
            }
            guard fileManager.itemExists(atPath: src.path) else {
                out.failures.append(TrashFailure(path: r.originalPath, message: L("trash.undo.notInTrash")))
                continue
            }
            guard let expected = r.identity else {
                out.failures.append(TrashFailure(path: r.originalPath,
                                                 message: L("trash.undo.unrecognized")))
                continue
            }
            guard fileManager.identity(atPath: src.path) == expected else {
                out.failures.append(TrashFailure(
                    path: r.originalPath,
                    message: L("trash.undo.replacedInTrash")))
                continue
            }
            guard !fileManager.itemExists(atPath: r.originalPath) else {
                out.failures.append(TrashFailure(path: r.originalPath,
                                                 message: L("trash.undo.occupied")))
                continue
            }
            let parent = (r.originalPath as NSString).deletingLastPathComponent
            guard fileManager.itemExists(atPath: parent) else {
                out.failures.append(TrashFailure(path: r.originalPath, message: L("trash.undo.parentMissing")))
                continue
            }
            do {
                try fileManager.moveItem(at: src, to: URL(fileURLWithPath: r.originalPath))
                out.restored.append(r.originalPath)
            } catch {
                out.failures.append(TrashFailure(path: r.originalPath, message: Self.describe(error)))
            }
        }
        return out
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, ns.domain == NSCocoaErrorDomain {
            return "\(ns.localizedDescription) (\(u.localizedDescription))"
        }
        return ns.localizedDescription
    }
}

// MARK: Baum nachführen

extension ScanTree {
    /// Entfernt die Knoten zu den gegebenen Pfaden (z. B. `TrashOutcome
    /// .removedPaths`); unbekannte Pfade werden übersprungen.
    public func removingNodes(atPaths paths: [String], compactIfNeeded: Bool = true) -> TreeEditChain {
        removingNodes(paths.compactMap { index(ofPath: $0) }, compactIfNeeded: compactIfNeeded)
    }
}
