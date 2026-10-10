@testable import DiskRingsCore
import Foundation
import Testing

/// Kontextmenü und Tastenkürzel im Vergleichsmodus (dev/DECISIONS.md,
/// „Kontextmenü im Vergleichsmodus“): Vergleichseinträge werden über den
/// Pfad auf den aktuellen Baum abgebildet; entfernte Elemente erlauben nur
/// „Pfad kopieren“ und „Hineinzoomen“.
@Suite("Aktionen im Vergleichsmodus", .language("de"))
struct CompareActionsTests {
    let noProtection = ProtectedPaths(home: "/nonexistent-home", appBundlePath: nil, volumeRoots: [])

    func entry(_ d: SnapshotDiff, _ rel: String) throws -> Int32 {
        try #require(d.entry(forPath: "/Users/demo" + (rel.isEmpty ? "" : "/" + rel)))
    }

    /// Vergleich „Snapshot ↔ aktueller Scan“; der aktuelle Baum ist `current`
    /// (Standard: der neue Baum des Vergleichs).
    func context(_ d: SnapshotDiff, current: ScanTree? = nil, focus: Int32 = 0, fullScan: Bool = false,
                 rescanning: [String] = [], protection: ProtectedPaths? = nil,
                 exists: @escaping @Sendable (String) -> Bool = { _ in false }) -> CompareActionContext {
        let tree = current ?? d.new.tree
        let ac = ActionContext(tree: tree, focus: ScanTree.rootIndex, protection: protection ?? noProtection,
                               sizeMode: .allocated, isFullScanRunning: fullScan, rescanningPaths: rescanning,
                               crossMountPoints: false)
        return CompareActionContext(diff: d, focusEntry: focus, sizeMode: .allocated, comparesSnapshots: false,
                                    current: ac, fileExists: exists)
    }

    // MARK: Abbildung auf den aktuellen Baum

    @Test("Bestehende Einträge werden über den Pfad auf den aktuellen Baum abgebildet")
    func mapsExistingEntries() throws {
        let d = CompareFixture.diff()
        let tree = d.new.tree
        for rel in ["", "Downloads", "Downloads/Xcode/a.xip", "Musik/album2.m4a", "Projekte/build.o"] {
            let e = try entry(d, rel)
            let n = try #require(CompareActions.node(forEntry: e, diff: d, in: tree))
            #expect(tree.path(of: n) == d.path(of: e))
        }
    }

    @Test("Entfernte Einträge haben keinen Knoten, auch wenn ein gleichnamiger Ordner fehlt")
    func removedEntriesHaveNoNode() throws {
        let d = CompareFixture.diff()
        #expect(CompareActions.node(forEntry: try entry(d, "Filme"), diff: d, in: d.new.tree) == nil)
        #expect(CompareActions.node(forEntry: try entry(d, "Filme/urlaub.mov"), diff: d, in: d.new.tree) == nil)
    }

    @Test("Abbildung auf einen später geänderten Baum (Papierkorb nach dem Vergleich)")
    func mapsIntoEditedTree() throws {
        let d = CompareFixture.diff()
        let x = try #require(d.new.tree.index(ofPath: "Downloads/Xcode"))
        let edited = d.new.tree.removingNode(at: x).tree
        // Die Indizes haben sich verschoben, die Pfade nicht.
        let musik = try entry(d, "Musik/album1.m4a")
        let n = try #require(CompareActions.node(forEntry: musik, diff: d, in: edited))
        #expect(edited.path(of: n) == "/Users/demo/Musik/album1.m4a")
        // Der gelöschte Ordner ist im aktuellen Baum nicht mehr da.
        #expect(CompareActions.node(forEntry: try entry(d, "Downloads/Xcode"), diff: d, in: edited) == nil)
        let c = context(d, current: edited)
        let a = CompareActions.availability(.moveToTrash, entries: [try entry(d, "Downloads/Xcode")], context: c)
        #expect(!a.isEnabled)
        #expect(a.reason == "Nicht mehr im aktuellen Scan")
    }

    // MARK: Verfügbarkeit

    @Test("Bestehende Einträge: alle Aktionen wie in der normalen Ansicht")
    func existingEntriesAllowEverything() throws {
        let d = CompareFixture.diff()
        let c = context(d)
        let dir = try entry(d, "Downloads/Xcode")
        for action in NodeAction.allCases {
            #expect(CompareActions.availability(action, entries: [dir], context: c).isEnabled, "\(action)")
        }
        let file = try entry(d, "Musik/album2.m4a")
        #expect(CompareActions.availability(.moveToTrash, entries: [file], context: c).isEnabled)
        #expect(CompareActions.availability(.quickLook, entries: [file], context: c).isEnabled)
        // Datei: kein Hineinzoomen, kein Rescan (gleiche Gründe wie in der normalen Ansicht).
        #expect(CompareActions.availability(.zoomIn, entries: [file], context: c) == .disabled("Nur für Ordner"))
        #expect(CompareActions.availability(.rescan, entries: [file], context: c) == .disabled("Nur für Ordner"))
    }

    @Test("Entfernte Einträge: nur Pfad kopieren und Hineinzoomen, sonst ausgegraut mit Begründung")
    func removedEntriesAreRestricted() throws {
        let d = CompareFixture.diff()
        let c = context(d)
        let filme = try entry(d, "Filme")
        #expect(CompareActions.availability(.copyPath, entries: [filme], context: c).isEnabled)
        #expect(CompareActions.availability(.zoomIn, entries: [filme], context: c).isEnabled)
        for action in [NodeAction.revealInFinder, .open, .quickLook, .info, .rescan, .moveToTrash] {
            let a = CompareActions.availability(action, entries: [filme], context: c)
            #expect(!a.isEnabled, "\(action)")
            #expect(a.reason == "„Filme“ existiert nicht mehr (seit dem Snapshot entfernt)")
        }
        // Mehrfachauswahl mit einem entfernten Element: ganze Aktion aus.
        let musik = try entry(d, "Musik")
        let a = CompareActions.availability(.moveToTrash, entries: [musik, filme], context: c)
        #expect(a == .disabled("Enthält entfernte Elemente, die es nicht mehr gibt"))
        #expect(CompareActions.availability(.copyPath, entries: [musik, filme], context: c).isEnabled)
    }

    @Test("Hineinzoomen im Vergleich: nur Ordner, nicht der aktuelle Fokus, nicht leer")
    func zoomInUsesCompareFocus() throws {
        let d = CompareFixture.diff()
        let dl = try entry(d, "Downloads")
        let c = context(d, focus: dl)
        #expect(CompareActions.availability(.zoomIn, entries: [dl], context: c) == .disabled("Ist bereits die Mitte"))
        #expect(CompareActions.availability(.zoomIn, entries: [0], context: c).isEnabled)
        let removedFile = try entry(d, "Filme/urlaub.mov")
        #expect(CompareActions.availability(.zoomIn, entries: [removedFile], context: c) == .disabled("Nur für Ordner"))
    }

    @Test("Schutzliste gilt auch im Vergleichsmodus (SPEC 9)")
    func protectionStillApplies() throws {
        let d = CompareFixture.diff()
        // Der Ordner „Musik“ gilt hier als Benutzerordner und ist geschützt.
        let prot = ProtectedPaths(home: "/Users/demo/Musik", appBundlePath: nil, volumeRoots: ["/"])
        let c = context(d, protection: prot)
        let musik = try entry(d, "Musik")
        let a = CompareActions.availability(.moveToTrash, entries: [musik], context: c)
        #expect(!a.isEnabled)
        #expect(a.reason != nil)
        #expect(CompareActions.availability(.moveToTrash, entries: [try entry(d, "Projekte")], context: c).isEnabled)
    }

    @Test("Während eines vollständigen Scans: kein Papierkorb, kein Rescan")
    func fullScanBlocks() throws {
        let d = CompareFixture.diff()
        let c = context(d, fullScan: true)
        let dir = try entry(d, "Projekte")
        #expect(!CompareActions.availability(.moveToTrash, entries: [dir], context: c).isEnabled)
        #expect(!CompareActions.availability(.rescan, entries: [dir], context: c).isEnabled)
        #expect(CompareActions.availability(.revealInFinder, entries: [dir], context: c).isEnabled)
    }

    @Test("Ohne aktuellen Scan: keine Aktionen auf den Baum, Finder nur, wenn der Pfad existiert")
    func comparingTwoSnapshots() throws {
        let d = CompareFixture.diff()
        var c = context(d, exists: { $0 == "/Users/demo/Musik" })
        c.comparesSnapshots = true
        c.current = nil
        let musik = try entry(d, "Musik")
        let proj = try entry(d, "Projekte")
        #expect(CompareActions.availability(.revealInFinder, entries: [musik], context: c).isEnabled)
        #expect(CompareActions.availability(.open, entries: [musik], context: c).isEnabled)
        #expect(CompareActions.availability(.quickLook, entries: [musik], context: c).isEnabled)
        #expect(CompareActions.availability(.copyPath, entries: [proj], context: c).isEnabled)
        #expect(CompareActions.availability(.revealInFinder, entries: [proj], context: c)
            == .disabled("„Projekte“ existiert nicht mehr auf dem Datenträger"))
        for action in [NodeAction.info, .rescan, .moveToTrash] {
            #expect(CompareActions.availability(action, entries: [musik], context: c)
                == .disabled("Beim Vergleich zweier Snapshots nicht möglich"), "\(action)")
        }
        #expect(CompareActions.availability(.zoomIn, entries: [musik], context: c).isEnabled)
    }

    @Test("Leere Auswahl und Mehrfachauswahl bei Einzelaktionen")
    func emptyAndMultiple() throws {
        let d = CompareFixture.diff()
        let c = context(d)
        #expect(CompareActions.availability(.copyPath, entries: [], context: c) == .disabled("Nichts ausgewählt"))
        let a = try entry(d, "Musik"), b = try entry(d, "Projekte")
        #expect(CompareActions.availability(.info, entries: [a, b], context: c) == .disabled("Nur für ein einzelnes Element"))
        #expect(CompareActions.availability(.zoomIn, entries: [a, b], context: c) == .disabled("Nur für ein einzelnes Element"))
        #expect(CompareActions.availability(.moveToTrash, entries: [a, b], context: c).isEnabled)
        #expect(CompareActions.nodes(forEntries: [a, b], context: c)?.count == 2)
        #expect(CompareActions.nodes(forEntries: [a, try entry(d, "Filme")], context: c) == nil)
    }

    @Test("Ungültige Eintragsnummern werden abgelehnt")
    func invalidEntries() {
        let d = CompareFixture.diff()
        let c = context(d)
        #expect(CompareActions.availability(.copyPath, entries: [-1], context: c) == .disabled("Element ist nicht mehr im Vergleich"))
        #expect(CompareActions.availability(.open, entries: [Int32(d.count)], context: c) == .disabled("Element ist nicht mehr im Vergleich"))
    }

    // MARK: Zustand nach Neuberechnung übertragen

    @Test("Nach Neuberechnung: Fokus, Historie, Auswahl und Aufgeklapptes über den Pfad übertragen")
    func transferAfterRecompute() throws {
        let old = CompareFixture.diff()
        // Neuberechnung nach dem Papierkorb: Downloads/Xcode ist weg.
        let x = try #require(old.new.tree.index(ofPath: "Downloads/Xcode"))
        let edited = old.new.tree.removingNode(at: x).tree
        let new = SnapshotDiff(old: old.old, new: Snapshot(metadata: old.new.metadata, tree: edited))

        let dl = try entry(old, "Downloads"), xe = try entry(old, "Downloads/Xcode"), musik = try entry(old, "Musik")
        var h = FocusHistory(root: 0)
        h.navigate(to: musik)
        h.navigate(to: dl)
        h.navigate(to: xe)
        let t = CompareEntryMapping(from: old, to: new)
        let h2 = t.history(h)
        // Xcode fehlt jetzt ganz (war nicht im alten Snapshot) → nächster Vorfahr Downloads.
        #expect(new.path(of: h2.current) == "/Users/demo/Downloads")
        #expect(h2.backStack.map { new.path(of: $0) } == ["/Users/demo", "/Users/demo/Musik"])
        #expect(t.map(xe) == nil)
        #expect(t.map(musik).map { new.path(of: $0) } == "/Users/demo/Musik")
        // Entfernte Einträge bleiben erhalten (aus dem alten Snapshot).
        let filme = try entry(old, "Filme")
        #expect(t.map(filme).map { new.status($0) } == .removed)
    }
}
