import Foundation

/// Umgebung für die Aktionen aus SPEC 3.5 im Vergleichsmodus.
public struct CompareActionContext: Sendable {
    public var diff: SnapshotDiff
    /// Fokus des Vergleichs (Eintrag in `diff.entries`).
    public var focusEntry: Int32
    public var sizeMode: SizeMode
    /// Zwei gespeicherte Snapshots ohne aktuellen Scan: Aktionen auf den Baum
    /// (Info, Rescan, Papierkorb) sind dann nicht möglich.
    public var comparesSnapshots: Bool
    /// Aktueller Scan (Baum, Schutzliste, laufende Scans); `nil`, wenn keiner da ist.
    public var current: ActionContext?
    /// Existiert der Pfad auf dem Datenträger? (Nur beim Vergleich zweier
    /// Snapshots gebraucht; in Tests austauschbar.)
    public var fileExists: @Sendable (String) -> Bool

    public init(diff: SnapshotDiff, focusEntry: Int32, sizeMode: SizeMode, comparesSnapshots: Bool,
                current: ActionContext?,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.diff = diff
        self.focusEntry = focusEntry
        self.sizeMode = sizeMode
        self.comparesSnapshots = comparesSnapshots
        self.current = current
        self.fileExists = fileExists
    }
}

/// Kontextmenü, Hauptmenü und Tastenkürzel im Vergleichsmodus
/// (docs/DECISIONS.md, „Kontextmenü im Vergleichsmodus“).
///
/// Ziele sind Vergleichseinträge. Für Aktionen auf das Dateisystem werden
/// sie über den Pfad auf den **aktuellen** Baum (`AppState.tree`) abgebildet;
/// die Prüfung übernimmt dann `NodeAction.availability` (samt Schutzliste).
/// Entfernte Elemente erlauben nur „Pfad kopieren“ und „Hineinzoomen“.
public enum CompareActions {
    /// Knoten des aktuellen Baums für einen Vergleichseintrag; `nil` für
    /// entfernte Einträge und für Pfade, die es im Baum nicht mehr gibt.
    public static func node(forEntry e: Int32, diff: SnapshotDiff, in tree: ScanTree) -> Int32? {
        guard e >= 0, Int(e) < diff.count, diff.entries[Int(e)].newIndex >= 0 else { return nil }
        guard let i = tree.index(ofPath: diff.path(of: e)), !tree.nodes[Int(i)].flags.contains(.dead) else {
            return nil
        }
        return i
    }

    /// Alle Ziele als Knoten des aktuellen Baums; `nil`, wenn eines fehlt.
    public static func nodes(forEntries entries: [Int32], context c: CompareActionContext) -> [Int32]? {
        guard let tree = c.current?.tree, !c.comparesSnapshots else { return nil }
        var out: [Int32] = []
        for e in entries {
            guard let n = node(forEntry: e, diff: c.diff, in: tree) else { return nil }
            out.append(n)
        }
        return out
    }

    public static func availability(_ action: NodeAction, entries: [Int32],
                                    context c: CompareActionContext) -> ActionAvailability {
        let d = c.diff
        guard !entries.isEmpty else { return .disabled("Nichts ausgewählt") }
        for e in entries where e < 0 || Int(e) >= d.count {
            return .disabled("Element ist nicht mehr im Vergleich")
        }
        if entries.count > 1, !action.allowsMultipleTargets { return .disabled("Nur für ein einzelnes Element") }
        let first = entries[0]
        switch action {
        case .copyPath:
            return .enabled
        case .zoomIn:
            // Navigation im Vergleich, auch in entfernte Ordner (Delta-Färbung zeigt sie).
            if !d.isDirectory(first) { return .disabled("Nur für Ordner") }
            if first == c.focusEntry { return .disabled("Ist bereits die Mitte") }
            if d.oldSize(first, c.sizeMode) == 0, d.newSize(first, c.sizeMode) == 0 {
                return .disabled("Ordner ist leer")
            }
            return .enabled
        case .revealInFinder, .open, .quickLook, .info, .rescan, .moveToTrash:
            break
        }
        let removed = entries.filter { d.entries[Int($0)].newIndex < 0 }
        if !removed.isEmpty {
            return entries.count == 1
                ? .disabled("„\(d.name(of: first))“ existiert nicht mehr (seit dem Snapshot entfernt)")
                : .disabled("Enthält entfernte Elemente, die es nicht mehr gibt")
        }
        if c.comparesSnapshots || c.current == nil {
            switch action {
            case .revealInFinder, .open, .quickLook:
                if let missing = entries.first(where: { !c.fileExists(d.path(of: $0)) }) {
                    return .disabled("„\(d.name(of: missing))“ existiert nicht mehr auf dem Datenträger")
                }
                return .enabled
            default:
                return .disabled("Beim Vergleich zweier Snapshots nicht möglich")
            }
        }
        guard let current = c.current, let nodes = nodes(forEntries: entries, context: c) else {
            return .disabled("Nicht mehr im aktuellen Scan")
        }
        return action.availability(targets: nodes, context: current)
    }
}

/// Überträgt den Zustand eines Vergleichs (Fokus, Historie, Auswahl,
/// aufgeklappte Ordner) auf einen neu berechneten Vergleich, z. B. nach
/// Papierkorb, Undo oder Teil-Rescan. Einträge werden über den Pfad
/// zugeordnet.
public struct CompareEntryMapping: Sendable {
    public let old: SnapshotDiff
    public let new: SnapshotDiff

    public init(from old: SnapshotDiff, to new: SnapshotDiff) {
        self.old = old
        self.new = new
    }

    public func map(_ e: Int32) -> Int32? {
        guard e >= 0, Int(e) < old.count else { return nil }
        return new.entry(forPath: old.path(of: e))
    }

    /// Wie `map`, fällt aber auf den nächsten noch vorhandenen Vorfahren zurück.
    public func mapOrAncestor(_ e: Int32) -> Int32 {
        var cur = e
        while cur >= 0, Int(cur) < old.count {
            if let m = map(cur) { return m }
            cur = old.entries[Int(cur)].parent
        }
        return 0
    }

    public func history(_ h: FocusHistory) -> FocusHistory {
        h.translated(current: mapOrAncestor(h.current), by: map)
    }
}
