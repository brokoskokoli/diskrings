@testable import DiskRingsCore
import Foundation
import Testing

/// Sichtbare Zeilen einer kleinen Outline:
///
///     A (aufgeklappt)
///       A1
///       A2 (zugeklappt, hat Kinder)
///       … (Sammelzeile, nicht auswählbar)
///     B (Datei)
///     C (zugeklappt, hat Kinder)
private let rows: [OutlineRow<String>] = [
    OutlineRow(id: "A", level: 0, isExpandable: true, isExpanded: true),
    OutlineRow(id: "A1", level: 1),
    OutlineRow(id: "A2", level: 1, isExpandable: true),
    OutlineRow(id: "more", level: 1, isSelectable: false),
    OutlineRow(id: "B", level: 0),
    OutlineRow(id: "C", level: 0, isExpandable: true),
]

@Suite("Tastaturnavigation in Listen (OutlineNavigation)")
struct OutlineNavigationTests {
    func cmd(_ key: OutlineKey, _ current: String?, _ r: [OutlineRow<String>] = rows) -> OutlineCommand<String> {
        OutlineNavigation.command(for: key, current: current, rows: r)
    }

    @Test("↑/↓ wechseln zur vorigen/nächsten auswählbaren Zeile, Sammelzeilen werden übersprungen")
    func upDown() {
        #expect(cmd(.down, "A") == .select("A1"))
        #expect(cmd(.down, "A1") == .select("A2"))
        #expect(cmd(.down, "A2") == .select("B"))
        #expect(cmd(.up, "B") == .select("A2"))
        #expect(cmd(.up, "A1") == .select("A"))
        // Am Rand passiert nichts.
        #expect(cmd(.up, "A") == .none)
        #expect(cmd(.down, "C") == .none)
    }

    @Test("Ohne (sichtbare) Auswahl: ↓/Pos1 wählen die erste, ↑/Ende die letzte Zeile")
    func noSelection() {
        #expect(cmd(.down, nil) == .select("A"))
        #expect(cmd(.home, nil) == .select("A"))
        #expect(cmd(.up, nil) == .select("C"))
        #expect(cmd(.end, nil) == .select("C"))
        #expect(cmd(.right, nil) == .select("A"))
        #expect(cmd(.left, nil) == .select("A"))
        // Auswahl nicht in den sichtbaren Zeilen (z. B. zugeklappt): wie ohne Auswahl.
        #expect(cmd(.down, "versteckt") == .select("A"))
        // Leere Liste.
        #expect(cmd(.down, nil, []) == .none)
        #expect(cmd(.end, "A", []) == .none)
    }

    @Test("→ klappt auf, auf einer aufgeklappten Zeile geht es zum ersten Kind")
    func right() {
        #expect(cmd(.right, "C") == .expand("C"))
        #expect(cmd(.right, "A2") == .expand("A2"))
        #expect(cmd(.right, "A") == .select("A1"))
        // Dateien: nichts.
        #expect(cmd(.right, "B") == .none)
        #expect(cmd(.right, "A1") == .none)
        // Aufgeklappt, aber erstes Kind nicht auswählbar (nur Sammelzeile): nichts.
        let onlyMore: [OutlineRow<String>] = [
            OutlineRow(id: "X", level: 0, isExpandable: true, isExpanded: true),
            OutlineRow(id: "more", level: 1, isSelectable: false),
        ]
        #expect(cmd(.right, "X", onlyMore) == .none)
    }

    @Test("← klappt zu; auf einer zugeklappten Zeile oder Datei geht es zum Elternordner")
    func left() {
        #expect(cmd(.left, "A") == .collapse("A"))
        #expect(cmd(.left, "A1") == .select("A"))
        #expect(cmd(.left, "A2") == .select("A"))
        // Oberste Ebene ohne Eltern in der Liste: nichts.
        #expect(cmd(.left, "B") == .none)
        #expect(cmd(.left, "C") == .none)
        // Tiefe Verschachtelung: nächster Vorfahr, nicht die Zeile davor.
        let deep: [OutlineRow<String>] = [
            OutlineRow(id: "P", level: 0, isExpandable: true, isExpanded: true),
            OutlineRow(id: "Q", level: 1, isExpandable: true, isExpanded: true),
            OutlineRow(id: "Q1", level: 2),
            OutlineRow(id: "Q2", level: 2),
            OutlineRow(id: "R", level: 1),
        ]
        #expect(cmd(.left, "Q2", deep) == .select("Q"))
        #expect(cmd(.left, "R", deep) == .select("P"))
    }

    @Test("Pos1/Ende und Bild↑/Bild↓ springen, begrenzt auf die Liste")
    func jumps() {
        #expect(cmd(.home, "B") == .select("A"))
        #expect(cmd(.end, "A") == .select("C"))
        // Schon am Ziel: nichts.
        #expect(cmd(.home, "A") == .none)
        #expect(cmd(.end, "C") == .none)
        let many = (0 ..< 30).map { OutlineRow(id: "r\($0)", level: 0) }
        #expect(OutlineNavigation.command(for: .pageDown, current: "r0", rows: many, pageSize: 10) == .select("r10"))
        #expect(OutlineNavigation.command(for: .pageDown, current: "r25", rows: many, pageSize: 10) == .select("r29"))
        #expect(OutlineNavigation.command(for: .pageUp, current: "r5", rows: many, pageSize: 10) == .select("r0"))
        #expect(OutlineNavigation.command(for: .pageUp, current: "r0", rows: many, pageSize: 10) == .none)
    }

    @Test("Nur Sammelzeilen: keine Auswahl möglich")
    func nothingSelectable() {
        let r: [OutlineRow<String>] = [OutlineRow(id: "more", level: 0, isSelectable: false)]
        for key in OutlineKey.allCases { #expect(cmd(key, nil, r) == .none) }
    }

    @Test("Zielzeile eines Befehls")
    func target() {
        #expect(OutlineCommand<String>.select("x").target == "x")
        #expect(OutlineCommand<String>.expand("y").target == nil)
        #expect(OutlineCommand<String>.none.target == nil)
    }
}

@Suite("VoiceOver-Wert einer Listenzeile", .language("en"))
struct OutlineAccessibilityTests {
    @Test("Ebene und Zustand werden genannt")
    func value() {
        #expect(OutlineAccessibility.value(level: 0, isExpandable: true, isExpanded: false) == "collapsed, level 1")
        #expect(OutlineAccessibility.value(level: 2, isExpandable: true, isExpanded: true) == "expanded, level 3")
        #expect(OutlineAccessibility.value(level: 1, isExpandable: false, isExpanded: false) == "level 2")
    }

    @Test("Deutsch", .language("de"))
    func german() {
        #expect(OutlineAccessibility.value(level: 0, isExpandable: true, isExpanded: true) == "aufgeklappt, Ebene 1")
        #expect(OutlineAccessibility.value(level: 4, isExpandable: false, isExpanded: false) == "Ebene 5")
    }
}
