/// Navigationsmodell für den Fokus des Diagramms: aktueller Knoten,
/// Zurück-/Vor-Stapel (SPEC 3.4 „Zurück/Vor“) und Breadcrumb-Pfad.
public struct FocusHistory: Sendable, Equatable {
    /// Höchstzahl gemerkter Schritte je Richtung.
    public static let limit = 200

    public private(set) var current: Int32
    public private(set) var backStack: [Int32] = []
    public private(set) var forwardStack: [Int32] = []

    public init(root: Int32 = ScanTree.rootIndex) {
        current = root
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Neuer Fokus; leert den Vor-Stapel. Gleicher Knoten: keine Änderung.
    public mutating func navigate(to node: Int32) {
        guard node != current else { return }
        backStack.append(current)
        if backStack.count > Self.limit { backStack.removeFirst(backStack.count - Self.limit) }
        forwardStack.removeAll()
        current = node
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let prev = backStack.popLast() else { return false }
        forwardStack.append(current)
        current = prev
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(current)
        current = next
        return true
    }

    /// Eine Ebene nach oben (Klick auf die Mitte). An der Wurzel: keine Änderung.
    @discardableResult
    public mutating func goUp(in tree: ScanTree) -> Bool {
        let p = tree.node(current).parent
        guard p >= 0 else { return false }
        navigate(to: p)
        return true
    }

    /// Überträgt die Historie auf einen neuen Baum desselben Wurzelpfads
    /// (Live-Snapshot → nächster Snapshot → Endergebnis, Rescan). Knoten werden
    /// über ihren Pfad zugeordnet; nicht mehr vorhandene Einträge entfallen,
    /// ein nicht mehr vorhandener Fokus wird durch seinen nächsten noch
    /// vorhandenen Vorfahren ersetzt.
    public func remapped(from old: ScanTree, to new: ScanTree) -> FocusHistory {
        func map(_ i: Int32) -> Int32? {
            guard i >= 0, Int(i) < old.count else { return nil }
            return new.index(ofPath: old.path(of: i))
        }
        var cur = current
        var mapped: Int32?
        while cur >= 0, Int(cur) < old.count {
            mapped = map(cur)
            if mapped != nil { break }
            cur = old.node(cur).parent
        }
        var h = FocusHistory(root: mapped ?? ScanTree.rootIndex)
        h.backStack = Self.dedupe(backStack.compactMap(map), excluding: h.current)
        h.forwardStack = Self.dedupe(forwardStack.compactMap(map), excluding: h.current)
        return h
    }

    /// Überträgt die Historie nach einer Änderung am Baum (Papierkorb,
    /// Teil-Rescan) über eine Index-Übersetzung wie `TreeEdit.translate`.
    /// Schneller als `remapped`, weil keine Pfade verglichen werden. Ein
    /// entfernter Fokus fällt auf seinen nächsten noch vorhandenen Vorfahren
    /// in `old` zurück; entfernte Einträge der Stapel entfallen.
    public func translated(from old: ScanTree, by map: (Int32) -> Int32?) -> FocusHistory {
        var cur = current
        var mapped: Int32?
        while cur >= 0, Int(cur) < old.count {
            mapped = map(cur)
            if mapped != nil { break }
            cur = old.node(cur).parent
        }
        var h = FocusHistory(root: mapped ?? ScanTree.rootIndex)
        h.backStack = Self.dedupe(backStack.compactMap(map), excluding: h.current)
        h.forwardStack = Self.dedupe(forwardStack.compactMap(map), excluding: h.current)
        return h
    }

    /// Entfernt direkt aufeinanderfolgende Duplikate und einen Eintrag gleich
    /// dem aktuellen Fokus am Stapelende.
    private static func dedupe(_ a: [Int32], excluding current: Int32) -> [Int32] {
        var out: [Int32] = []
        for x in a where out.last != x { out.append(x) }
        while out.last == current { out.removeLast() }
        return out
    }
}

public enum Breadcrumb {
    /// Knoten von der Wurzel bis `node` (einschließlich).
    public static func path(in tree: ScanTree, to node: Int32) -> [Int32] {
        var out: [Int32] = []
        var i = node
        while i >= 0 {
            out.append(i)
            i = tree.node(i).parent
        }
        return out.reversed()
    }

    /// Ist `ancestor` ein Vorfahr von `node` (oder der Knoten selbst)?
    public static func isAncestor(_ ancestor: Int32, of node: Int32, in tree: ScanTree) -> Bool {
        var i = node
        while i >= 0 {
            if i == ancestor { return true }
            i = tree.node(i).parent
        }
        return false
    }
}
