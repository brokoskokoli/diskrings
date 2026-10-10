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
    /// Ist hier ein anderes Volume eingehängt (Ordner auf einem anderen
    /// Gerät als sein Elternordner)?
    func isMountPoint(atPath path: String) -> Bool
}

extension FileTrashing {
    public func identity(atPath path: String) -> FileIdentity? { FileIdentity(path: path) }

    public func resolvedPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// Über `statfs`: Der Einhängeort des Volumes ist genau dieser Ordner.
    /// (Ein Vergleich der Geräte mit dem Elternordner träfe auch die
    /// Firmlinks wie `/Applications`, die auf dem Data-Volume liegen.)
    public func isMountPoint(atPath path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, let resolved = resolvedPath(path) else {
            return false
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return mountedOn == resolved
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
    /// Die Größe ist nicht verlässlich: Im Teilbaum liegt etwas nur in der
    /// Cloud, nicht Lesbares oder ein Einhängepunkt (zählt mit 0 Byte), der
    /// Baum ist dort unvollständig, oder die Art auf der Platte hat sich
    /// seit dem Scan geändert bzw. die Datei ist deutlich gewachsen. Dann
    /// wird immer nachgefragt.
    public var sizeIsUncertain: Bool

    public init(node: Int32, path: String, name: String, isDirectory: Bool, allocatedSize: UInt64,
                logicalSize: UInt64, fileCount: Int, sizeIsUncertain: Bool = false) {
        self.node = node
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize
        self.logicalSize = logicalSize
        self.fileCount = fileCount
        self.sizeIsUncertain = sizeIsUncertain
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
    /// Einhängepunkt eines anderen Volumes.
    case mountPoint(path: String)
    /// Der Ordner enthält einen Einhängepunkt.
    case containsMountPoint(path: String, mountPoint: String)

    public var message: String {
        switch self {
        case .empty: L("reason.nothingSelected")
        case .scanRoot: L("trash.error.scanRoot")
        case .protected(let p, let r):
            p.isEmpty ? L("trash.error.protected", r.message)
                : L("trash.error.protectedItem", r.message, (p as NSString).lastPathComponent)
        case .notLive: L("reason.notInTree")
        case .mountPoint(let p): L("trash.error.mountPoint", (p as NSString).lastPathComponent)
        case .containsMountPoint(_, let m): L("trash.error.containsMountPoint", m)
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

    /// Prüft Auswahl, Scan-Wurzel, Schutzliste und Einhängepunkte und baut
    /// den Plan. `incompletePaths`: Ordner, die gerade neu eingelesen werden
    /// (darin oder darüber ist die Größe unsicher).
    public static func make(targets: [Int32], in tree: ScanTree, protection: ProtectedPaths,
                            sizeMode: SizeMode = .allocated,
                            incompletePaths: [String] = []) -> Result<TrashPlan, TrashPlanError> {
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
            if node.flags.contains(.mountPoint) { return .failure(.mountPoint(path: path)) }
            let scan = inspectSubtree(n, in: tree)
            if let m = scan.mountPoint {
                return .failure(.containsMountPoint(path: path, mountPoint: tree.path(of: m)))
            }
            let key = ProtectedPaths.normalize(path)
            let rescanning = incompletePaths.contains { p in
                let k = ProtectedPaths.normalize(p)
                return ProtectedPaths.isWithin(k, key) || ProtectedPaths.isWithin(key, k)
            }
            items.append(TrashItem(node: n, path: path, name: tree.name(of: n), isDirectory: node.isDirectory,
                                   allocatedSize: node.allocatedSize, logicalSize: node.logicalSize,
                                   fileCount: node.isDirectory ? Int(node.fileCount) : 1,
                                   sizeIsUncertain: scan.uncertain || !tree.isComplete || rescanning))
        }
        return .success(TrashPlan(items: items, sizeMode: sizeMode, rootPath: tree.rootPath))
    }

    /// Durchläuft den Teilbaum einmal: erster Einhängepunkt darunter und
    /// ob etwas mit unbekannter Größe darin liegt (der Knoten selbst zählt mit).
    static func inspectSubtree(_ n: Int32, in tree: ScanTree) -> (mountPoint: Int32?, uncertain: Bool) {
        let unknown: NodeFlags = [.dataless, .unreadable, .mountPoint]
        var uncertain = !tree.nodes[Int(n)].flags.isDisjoint(with: unknown)
        var stack: [Int32] = [n]
        while let i = stack.popLast() {
            for c in tree.childIndices(of: i) {
                let f = tree.nodes[Int(c)].flags
                if f.contains(.mountPoint) { return (c, true) }
                if !f.isDisjoint(with: unknown) { uncertain = true }
                if tree.nodes[Int(c)].childCount > 0 { stack.append(c) }
            }
        }
        return (nil, uncertain)
    }

    /// Vergleicht jedes Element per `lstat` mit dem Scan: Hat sich die Art
    /// (Ordner oder nicht) geändert, ist die Größe unsicher. Bei Dateien
    /// ebenso, wenn die logische Größe deutlich über der Scan-Größe
    /// (`limitSize`) liegt (`grewNoticeably`) oder das Wachstum den Plan über
    /// die 1-GB-Grenze für „Nicht mehr fragen“ hebt.
    public func checkingCurrentKinds(using fileManager: any FileTrashing) -> TrashPlan {
        var out = self
        var currentLimit: UInt64 = 0
        var grown: [Int] = []
        for i in out.items.indices {
            let item = out.items[i]
            var size = item.limitSize
            if let id = fileManager.identity(atPath: item.path) {
                if id.isDirectory != item.isDirectory {
                    out.items[i].sizeIsUncertain = true
                } else if !id.isDirectory, let now = id.size, now > item.limitSize {
                    size = now
                    grown.append(i)
                    if Self.grewNoticeably(from: item.limitSize, to: now) { out.items[i].sizeIsUncertain = true }
                }
            }
            currentLimit &+= size
        }
        if limitSize < TrashConfirmation.dontAskLimit, currentLimit >= TrashConfirmation.dontAskLimit {
            for i in grown { out.items[i].sizeIsUncertain = true }
        }
        return out
    }

    /// Wachstum über die Scan-Größe hinaus, das mehr als 10 % und mehr als
    /// 1 MB beträgt.
    static func grewNoticeably(from scanned: UInt64, to now: UInt64) -> Bool {
        guard now > scanned else { return false }
        return now - scanned > max(1_000_000, scanned / 10)
    }

    public var hasUncertainSize: Bool { items.contains { $0.sizeIsUncertain } }

    /// Warum der Dialog „Nicht mehr fragen“ nicht anbietet.
    public var alwaysAskReason: String {
        hasUncertainSize ? L("trash.confirm.sizeUncertain") : L("trash.confirm.alwaysAsk")
    }

    public var totalSize: UInt64 {
        items.reduce(0) { $0 + (sizeMode == .allocated ? $1.allocatedSize : $1.logicalSize) }
    }
    public var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
    var limitSize: UInt64 { items.reduce(0) { $0 + $1.limitSize } }

    /// „Nicht mehr fragen“ ist nur unter 1 GB und bei sicherer Größe zulässig.
    public var allowsDontAskAgain: Bool { limitSize < TrashConfirmation.dontAskLimit && !hasUncertainSize }

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
    /// Elternordner mit aufgelösten Symlinks (`realpath`) beim Verschieben.
    /// ⌘Z legt nur zurück, wenn der Elternordner noch genau dorthin
    /// aufgelöst wird; `nil` → Vergleich mit dem Elternpfad selbst.
    public var resolvedParent: String?
    /// Identität (Gerät und Inode) des aufgelösten Elternordners beim
    /// Verschieben. ⌘Z legt nur zurück, wenn dort noch derselbe Ordner liegt
    /// (nicht ein neuer gleichen Namens); `nil` → keine Prüfung (alte Einträge).
    public var parentIdentity: FileIdentity?

    public init(originalPath: String, trashURL: URL?, name: String, allocatedSize: UInt64,
                identity: FileIdentity? = nil, resolvedParent: String? = nil, parentIdentity: FileIdentity? = nil) {
        self.originalPath = originalPath
        self.trashURL = trashURL
        self.name = name
        self.allocatedSize = allocatedSize
        self.identity = identity
        self.resolvedParent = resolvedParent
        self.parentIdentity = parentIdentity
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
            if fileManager.isMountPoint(atPath: item.path) {
                out.failures.append(TrashFailure(path: item.path, message: TrashPlanError.mountPoint(path: item.path).message))
                continue
            }
            if let problem = checkResolved(item.path, rootPath: plan.rootPath) {
                out.failures.append(TrashFailure(path: item.path, message: problem))
                continue
            }
            let identity = fileManager.identity(atPath: item.path)
            let resolvedParent = fileManager.resolvedPath((item.path as NSString).deletingLastPathComponent)
            let parentIdentity = resolvedParent.flatMap { fileManager.identity(atPath: $0) }
            do {
                let url = try fileManager.trashItem(at: URL(fileURLWithPath: item.path))
                out.trashed.append(TrashRecord(originalPath: item.path, trashURL: url, name: item.name,
                                               allocatedSize: item.allocatedSize, identity: identity,
                                               resolvedParent: resolvedParent, parentIdentity: parentIdentity))
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
            if let problem = checkRestoreTarget(r) {
                out.failures.append(TrashFailure(path: r.originalPath, message: problem))
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

    /// Prüft vor ⌘Z die Elternkette erneut: Wurde ein Elternordner
    /// inzwischen durch einen Symlink ersetzt (oder verschoben), würde
    /// `moveItem` das Element an einen ganz anderen Ort legen. Außerdem darf
    /// der aufgelöste Zielort nicht geschützt sein. Fehlermeldung oder `nil`.
    func checkRestoreTarget(_ r: TrashRecord) -> String? {
        let parent = (r.originalPath as NSString).deletingLastPathComponent
        guard let resolved = fileManager.resolvedPath(parent),
              ProtectedPaths.normalize(resolved) == ProtectedPaths.normalize(r.resolvedParent ?? parent) else {
            return L("trash.undo.parentChanged")
        }
        // Gleicher Pfad, aber ein anderer Ordner (verschoben und neu angelegt)?
        if let expected = r.parentIdentity {
            guard let current = fileManager.identity(atPath: resolved),
                  current.device == expected.device, current.inode == expected.inode,
                  current.isDirectory == expected.isDirectory else {
                return L("trash.undo.parentChanged")
            }
        }
        let name = (r.originalPath as NSString).lastPathComponent
        let target = resolved == "/" ? "/" + name : resolved + "/" + name
        if let reason = protection.reason(for: target) ?? protection.reason(for: r.originalPath) {
            return L("trash.error.protected", reason.message)
        }
        return nil
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
