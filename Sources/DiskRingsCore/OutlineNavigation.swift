/// Eine sichtbare Zeile einer Outline-Liste (Detailliste, Vergleichsliste,
/// „Größte Veränderungen“), so wie die Tastaturnavigation sie sieht.
public struct OutlineRow<ID: Hashable & Sendable>: Sendable, Equatable {
    public let id: ID
    /// Einrückungsebene, 0 = oberste Ebene.
    public let level: Int
    /// Sammelzeilen („N kleinere Elemente“) sind nicht auswählbar.
    public let isSelectable: Bool
    /// Ordner mit Kindern.
    public let isExpandable: Bool
    public let isExpanded: Bool

    public init(id: ID, level: Int, isSelectable: Bool = true, isExpandable: Bool = false, isExpanded: Bool = false) {
        self.id = id
        self.level = level
        self.isSelectable = isSelectable
        self.isExpandable = isExpandable
        self.isExpanded = isExpandable && isExpanded
    }
}

/// Tasten der Listen-Navigation.
public enum OutlineKey: Sendable, CaseIterable {
    case up, down, left, right, home, end, pageUp, pageDown
}

/// Ergebnis eines Tastendrucks.
public enum OutlineCommand<ID: Hashable & Sendable>: Sendable, Equatable {
    /// Diese Zeile auswählen (und sichtbar machen).
    case select(ID)
    case expand(ID)
    case collapse(ID)
    case none

    /// Die neu auszuwählende Zeile, falls der Befehl die Auswahl bewegt.
    public var target: ID? {
        if case .select(let id) = self { return id }
        return nil
    }
}

/// Tastaturbedienung einer Outline wie im Finder (SPEC 5, Barrierefreiheit):
///
/// - ↑/↓: vorige/nächste auswählbare Zeile (Sammelzeilen werden übersprungen);
///   ohne sichtbare Auswahl ↓ die erste, ↑ die letzte Zeile.
/// - →: zugeklappten Ordner aufklappen; auf einem aufgeklappten Ordner zum ersten Kind.
/// - ←: aufgeklappten Ordner zuklappen; sonst zum Elternordner (nächste Zeile
///   davor mit kleinerer Ebene).
/// - Pos1/Ende, Bild↑/Bild↓: erste/letzte Zeile bzw. eine Seite weiter.
///
/// Reine Funktion auf den sichtbaren Zeilen; die Oberfläche führt den Befehl aus.
public enum OutlineNavigation {
    public static func command<ID>(for key: OutlineKey, current: ID?, rows: [OutlineRow<ID>],
                                   pageSize: Int = 10) -> OutlineCommand<ID> {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard let first = selectable.first, let last = selectable.last else { return .none }
        guard let current, let i = rows.firstIndex(where: { $0.id == current }), rows[i].isSelectable else {
            // Keine (sichtbare) Auswahl: am Anfang bzw. Ende beginnen.
            switch key {
            case .up, .end, .pageUp: return .select(rows[last].id)
            default: return .select(rows[first].id)
            }
        }
        let row = rows[i]
        // Position der aktuellen Zeile unter den auswählbaren.
        let pos = selectable.firstIndex(of: i)!
        func select(at p: Int) -> OutlineCommand<ID> {
            let q = min(max(p, 0), selectable.count - 1)
            return q == pos ? .none : .select(rows[selectable[q]].id)
        }
        switch key {
        case .down: return select(at: pos + 1)
        case .up: return select(at: pos - 1)
        case .home: return select(at: 0)
        case .end: return select(at: selectable.count - 1)
        case .pageDown: return select(at: pos + max(pageSize, 1))
        case .pageUp: return select(at: pos - max(pageSize, 1))
        case .right:
            guard row.isExpandable else { return .none }
            if !row.isExpanded { return .expand(row.id) }
            let next = i + 1
            if next < rows.count, rows[next].level == row.level + 1, rows[next].isSelectable {
                return .select(rows[next].id)
            }
            return .none
        case .left:
            if row.isExpanded { return .collapse(row.id) }
            var j = i - 1
            while j >= 0 {
                if rows[j].level < row.level { return rows[j].isSelectable ? .select(rows[j].id) : .none }
                j -= 1
            }
            return .none
        }
    }
}

/// VoiceOver-Texte einer Outline-Zeile.
public enum OutlineAccessibility {
    /// Wert einer Zeile: Zustand (auf-/zugeklappt) und Ebene (ab 1 gezählt).
    public static func value(level: Int, isExpandable: Bool, isExpanded: Bool) -> String {
        let n = ByteFormat.count(level + 1)
        guard isExpandable else { return L("outline.value.leaf", n) }
        return isExpanded ? L("outline.value.expanded", n) : L("outline.value.collapsed", n)
    }
}
