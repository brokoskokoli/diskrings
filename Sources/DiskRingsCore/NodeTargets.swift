/// Art eines Elements, wie sie beim Festhalten der Ziele verglichen wird.
public enum NodeTargetKind: Sendable, Equatable {
    case file
    case directory
    case symlink

    public init(_ flags: NodeFlags) {
        if flags.contains(.directory) {
            self = .directory
        } else if flags.contains(.symlink) {
            self = .symlink
        } else {
            self = .file
        }
    }
}

/// Ein festgehaltenes Ziel: absoluter Pfad und Art.
public struct NodeTargetEntry: Sendable, Equatable {
    public var path: String
    public var kind: NodeTargetKind

    public init(path: String, kind: NodeTargetKind) {
        self.path = path
        self.kind = kind
    }
}

/// Ziele eines Kontextmenüs, über Pfad und Art statt über Knotenindizes
/// festgehalten (docs/DECISIONS.md, „Kontextmenü: Ziele über Pfade“).
///
/// Ein Menü bleibt offen, während im Hintergrund z. B. ein Teil-Rescan
/// fertig wird; der Baum wird dann ersetzt und beim Kompaktieren
/// umnummeriert. Ein alter Index könnte danach auf ein ganz anderes
/// Element zeigen. Vor der Ausführung wird deshalb jeder Pfad im aktuellen
/// Baum neu aufgelöst; fehlt einer oder hat er eine andere Art, wird nichts
/// ausgeführt.
public struct NodeTargetSnapshot: Sendable, Equatable {
    public let rootPath: String
    public let entries: [NodeTargetEntry]
    /// Alle Indizes waren beim Festhalten gültige, lebende Knoten.
    public let isValid: Bool

    public init(nodes: [Int32], in tree: ScanTree) {
        rootPath = tree.rootPath
        var valid = !nodes.isEmpty
        var out: [NodeTargetEntry] = []
        out.reserveCapacity(nodes.count)
        for n in nodes {
            guard n >= 0, Int(n) < tree.count, !tree.nodes[Int(n)].flags.contains(.dead) else {
                valid = false
                continue
            }
            out.append(NodeTargetEntry(path: tree.path(of: n), kind: NodeTargetKind(tree.nodes[Int(n)].flags)))
        }
        entries = out
        isValid = valid
    }

    /// Indizes der Ziele im Baum `tree`, in derselben Reihenfolge; `nil`,
    /// wenn ein Ziel fehlt, eine andere Art hat oder der Baum eine andere
    /// Scan-Wurzel hat. Verglichen wird der Pfad bytegenau (kein Treffer
    /// über eine andere Unicode-Normalform).
    public func resolve(in tree: ScanTree?) -> [Int32]? {
        guard isValid, let tree, tree.rootPath == rootPath else { return nil }
        var out: [Int32] = []
        out.reserveCapacity(entries.count)
        for e in entries {
            guard let i = tree.index(ofPath: e.path), !tree.nodes[Int(i)].flags.contains(.dead),
                  NodeTargetKind(tree.nodes[Int(i)].flags) == e.kind, tree.path(of: i) == e.path else { return nil }
            out.append(i)
        }
        return out
    }
}

/// Dasselbe für Einträge eines Vergleichs (`SnapshotDiff.entries`): Nach
/// Papierkorb oder Teil-Rescan wird der Vergleich neu berechnet, die
/// Eintragsnummern ändern sich.
public struct CompareTargetSnapshot: Sendable, Equatable {
    /// Pfad und „ist Ordner“ je Eintrag.
    public let entries: [NodeTargetEntry]
    public let isValid: Bool

    public init(entries: [Int32], in diff: SnapshotDiff) {
        var valid = !entries.isEmpty
        var out: [NodeTargetEntry] = []
        for e in entries {
            guard e >= 0, Int(e) < diff.count else {
                valid = false
                continue
            }
            out.append(NodeTargetEntry(path: diff.path(of: e), kind: diff.isDirectory(e) ? .directory : .file))
        }
        self.entries = out
        isValid = valid
    }

    /// Einträge in `diff`; `nil`, wenn einer fehlt oder die Art (Ordner
    /// oder nicht) sich geändert hat.
    public func resolve(in diff: SnapshotDiff?) -> [Int32]? {
        guard isValid, let diff else { return nil }
        var out: [Int32] = []
        for t in entries {
            guard let e = diff.entry(forPath: t.path), diff.path(of: e) == t.path,
                  (diff.isDirectory(e) ? NodeTargetKind.directory : .file) == t.kind else { return nil }
            out.append(e)
        }
        return out
    }
}
