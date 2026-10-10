@testable import DiskRingsCore
import Foundation
import Testing

/// Baut zwei kleine Bäume im Speicher (ohne Dateisystem) für die
/// Vergleichsmodell-Tests.
///
/// Vorher:                         Nachher:
///   home/                           home/
///     Downloads/alt.zip   30 MB       Downloads/alt.zip   30 MB
///                                     Downloads/Xcode/a.xip 60 MB  (neu)
///                                     Downloads/Xcode/b.xip 40 MB  (neu)
///     Filme/urlaub.mov    50 MB       (Filme/ entfernt)
///     Musik/album1.m4a    20 MB       Musik/album1.m4a    20 MB
///     Musik/album2.m4a    10 MB       Musik/album2.m4a     4 MB (geschrumpft)
///     Projekte/build.o    10 MB       Projekte/build.o    25 MB (gewachsen)
enum CompareFixture {
    static let MB: UInt64 = 1_000_000
    static let oldDate = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-02 …
    static let newDate = Date(timeIntervalSince1970: 1_791_600_000)

    static func oldTree() -> ScanTree {
        var b = ScanTreeBuilder(rootName: "home")
        let dl = b.directory("Downloads")
        b.file("alt.zip", size: 30 * MB, in: dl)
        let filme = b.directory("Filme")
        b.file("urlaub.mov", size: 50 * MB, in: filme)
        let musik = b.directory("Musik")
        b.file("album1.m4a", size: 20 * MB, in: musik)
        b.file("album2.m4a", size: 10 * MB, in: musik)
        let proj = b.directory("Projekte")
        b.file("build.o", size: 10 * MB, in: proj)
        return b.build(rootPath: "/Users/demo")
    }

    static func newTree() -> ScanTree {
        var b = ScanTreeBuilder(rootName: "home")
        let dl = b.directory("Downloads")
        b.file("alt.zip", size: 30 * MB, in: dl)
        let x = b.directory("Xcode", in: dl)
        b.file("a.xip", size: 60 * MB, in: x)
        b.file("b.xip", size: 40 * MB, in: x)
        let musik = b.directory("Musik")
        b.file("album1.m4a", size: 20 * MB, in: musik)
        b.file("album2.m4a", size: 4 * MB, in: musik)
        let proj = b.directory("Projekte")
        b.file("build.o", size: 25 * MB, in: proj)
        return b.build(rootPath: "/Users/demo")
    }

    static func volume(used: UInt64, total: UInt64 = 1_000 * MB, unassigned: UInt64? = nil) -> VolumeMetrics {
        VolumeMetrics(name: "Macintosh HD", total: total, available: total - used,
                      availableForImportantUsage: total - used, used: used, unassigned: unassigned)
    }

    static func diff(oldVolume: VolumeMetrics? = nil, newVolume: VolumeMetrics? = nil,
                     oldOptions: SnapshotScanOptions = SnapshotScanOptions()) -> SnapshotDiff {
        let o = oldTree(), n = newTree()
        let om = SnapshotMetadata(name: "vor Xcode-Update", date: oldDate, rootPath: o.rootPath, volumeUUID: "V1",
                                  volume: oldVolume, options: oldOptions, allocatedSize: o.root.allocatedSize)
        let nm = SnapshotMetadata(date: newDate, rootPath: n.rootPath, volumeUUID: "V1", volume: newVolume,
                                  allocatedSize: n.root.allocatedSize)
        return SnapshotDiff(old: Snapshot(metadata: om, tree: o), new: Snapshot(metadata: nm, tree: n))
    }

    static func model(_ mode: SizeMode = .allocated) -> CompareModel { CompareModel(diff: diff(), mode: mode) }
}

@Suite("Vergleichsmodell", .language("de"))
struct CompareModelTests {
    let MB = CompareFixture.MB

    func entry(_ m: CompareModel, _ rel: String) throws -> Int32 {
        try #require(m.diff.entry(forPath: "/Users/demo" + (rel.isEmpty ? "" : "/" + rel)))
    }

    // MARK: Anzeigebäume

    @Test("Vergleichsbaum (Delta-Ansicht): neue Größen, entfernte mit alter Größe, gültiger Baum")
    func unionTree() throws {
        let m = CompareFixture.model()
        let t = m.union.tree
        expectValidTree(t)
        #expect(t.rootPath == "/Users/demo")
        // Wurzel = neue Größe + entfernte Teilbäume (Filme 50 MB).
        let newRoot = m.diff.new.tree.root.allocatedSize
        #expect(t.root.allocatedSize == newRoot + 50 * MB)
        let filme = try #require(t.index(ofPath: "Filme"))
        #expect(t.node(filme).allocatedSize == 50 * MB)
        let film = try #require(t.index(ofPath: "Filme/urlaub.mov"))
        #expect(m.diff.status(m.union.entry(ofNode: film)) == .removed)
        // Bestehende Knoten haben die neue Größe.
        let musik = try #require(t.index(ofPath: "Musik"))
        #expect(t.node(musik).allocatedSize == 24 * MB)
        // Abbildung in beide Richtungen.
        for i in 0 ..< Int32(t.count) {
            let e = m.union.entry(ofNode: i)
            #expect(e >= 0)
            #expect(m.union.node(forEntry: e) == i)
            #expect(m.diff.name(of: e) == t.name(of: i))
        }
        // Jeder Vergleichseintrag hat einen Knoten.
        #expect(t.count == m.diff.count)
    }

    @Test("Wachstumsbaum: Abbildung auf Einträge, Elternordner des neuen Ordners dominiert")
    func growthTree() throws {
        let m = CompareFixture.model()
        let g = m.growth.tree
        expectValidTree(g)
        // Brutto-Zuwachs: Xcode 100 MB + build.o 15 MB.
        #expect(g.root.allocatedSize == 115 * MB)
        #expect(g.root.children.first?.name == "Downloads")
        #expect(g.root.children.first!.allocatedSize * 2 > g.root.allocatedSize)
        let x = try #require(g.index(ofPath: "Downloads/Xcode"))
        #expect(m.growth.entry(ofNode: x) == (try entry(m, "Downloads/Xcode")))
        // Kein Zuwachs → nicht im Wachstumsbaum.
        #expect(m.growth.node(forEntry: try entry(m, "Musik")) == nil)
        #expect(m.growth.node(forEntry: try entry(m, "Filme")) == nil)
    }

    @Test("Fokus im Anzeigebaum: fehlt der Eintrag, gilt der nächste vorhandene Vorfahr")
    func displayFocus() throws {
        let m = CompareFixture.model()
        let album2 = try entry(m, "Musik/album2.m4a")
        // Im Wachstumsbaum fehlen Musik und album2 → Wurzel.
        #expect(m.displayFocus(forEntry: album2, in: .growth) == ScanTree.rootIndex)
        let x = try entry(m, "Downloads/Xcode")
        let gx = try #require(m.growth.tree.index(ofPath: "Downloads/Xcode"))
        #expect(m.displayFocus(forEntry: x, in: .growth) == gx)
        let ux = try #require(m.union.tree.index(ofPath: "Downloads/Xcode"))
        #expect(m.displayFocus(forEntry: x, in: .delta) == ux)
        // Eine Datei als Fokus wird zum Elternordner.
        let a = try entry(m, "Downloads/Xcode/a.xip")
        #expect(m.displayFocus(forEntry: a, in: .delta) == ux)
    }

    @Test("Layout und Hit-Test im Vergleichsmodus treffen den richtigen Eintrag")
    func layoutAndHitTest() throws {
        let m = CompareFixture.model()
        for view in CompareViewMode.allCases {
            let layout = m.layout(view, focusEntry: 0, options: SunburstOptions())
            #expect(!layout.isEmpty)
            let geo = SunburstGeometry(rings: layout.options.maxRings, outerRadius: 300)
            let tester = SunburstHitTester(layout: layout, geometry: geo)
            for (i, arc) in layout.arcs.enumerated() where arc.kind == .node {
                let r = (geo.innerRadius(ofRing: Int(arc.depth)) + geo.outerRadius(ofRing: Int(arc.depth))) / 2
                let hit = tester.hit(dx: r * sin(arc.midAngle), dy: -r * cos(arc.midAngle))
                #expect(hit == .arc(i))
                let e = try #require(m.entry(at: hit, layout: layout, view: view))
                #expect(m.diff.name(of: e) == m.displayTree(view).tree.name(of: arc.nodeIndex))
            }
            // Mitte und außerhalb: kein Eintrag.
            #expect(m.entry(at: .center, layout: layout, view: view) == nil)
            #expect(m.entry(at: .none, layout: layout, view: view) == nil)
        }
        // Wachstum: der größte Arc in Ring 1 ist Downloads.
        let g = m.layout(.growth, focusEntry: 0, options: SunburstOptions())
        let first = try #require(g.arcs(inRing: 1).first)
        #expect(m.diff.name(of: try #require(m.entry(for: first, view: .growth))) == "Downloads")
        #expect(first.span > .pi) // mehr als die Hälfte des Kreises
    }

    @Test("Drill-down: Layout ab einem Unterordner")
    func drillDown() throws {
        let m = CompareFixture.model()
        let dl = try entry(m, "Downloads")
        let layout = m.layout(.growth, focusEntry: dl, options: SunburstOptions())
        #expect(layout.focus == m.growth.tree.index(ofPath: "Downloads"))
        let names = layout.arcs(inRing: 1).compactMap { m.entry(for: $0, view: .growth) }.map { m.diff.name(of: $0) }
        #expect(names == ["Xcode"])
    }

    @Test("Markierungen: neu, entfernt; Statusabfrage pro Arc")
    func marks() throws {
        let m = CompareFixture.model()
        let layout = m.layout(.delta, focusEntry: 0, options: SunburstOptions())
        var seen: [String: DiffStatus] = [:]
        for arc in layout.arcs where arc.kind == .node {
            let e = try #require(m.entry(for: arc, view: .delta))
            seen[m.diff.name(of: e)] = m.status(of: arc, view: .delta)
        }
        #expect(seen["Xcode"] == .added)
        #expect(seen["Filme"] == .removed)
        #expect(seen["urlaub.mov"] == .removed)
        #expect(seen["Musik"] == .shrunk)
        #expect(seen["Projekte"] == .grown)
        #expect(seen["alt.zip"] == .unchanged)
    }

    // MARK: Farben

    @Test("Delta-Färbung: orange gewachsen, blau geschrumpft, grau entfernt/unverändert")
    func deltaColors() throws {
        let m = CompareFixture.model()
        for appearance in PaletteAppearance.allCases {
            let palette = Palette(appearance: appearance)
            let layout = m.layout(.delta, focusEntry: 0, options: SunburstOptions())
            let colors = m.colors(for: layout, view: .delta, palette: palette)
            #expect(colors.count == layout.arcs.count)
            for (i, arc) in layout.arcs.enumerated() where arc.kind == .node {
                let c = colors[i]
                switch m.status(of: arc, view: .delta) {
                case .grown, .added:
                    #expect(DeltaPaletteTests.isOrange(c), "\(c) sollte orange sein")
                case .shrunk:
                    #expect(DeltaPaletteTests.isBlue(c), "\(c) sollte blau sein")
                case .removed:
                    #expect(c == palette.removedFill)
                case .unchanged:
                    #expect(c == palette.unchangedFill)
                case nil:
                    Issue.record("Status fehlt")
                }
            }
        }
    }

    @Test("Wachstumsansicht nutzt das normale Farbschema")
    func growthColors() {
        let m = CompareFixture.model()
        let palette = Palette()
        let layout = m.layout(.growth, focusEntry: 0, options: SunburstOptions())
        #expect(m.colors(for: layout, view: .growth, palette: palette) == palette.colors(for: layout, tree: m.growth.tree))
    }

    @Test("Intensitätsskala bezieht sich auf die größte Änderung im ersten Ring")
    func scaleForLayout() throws {
        let m = CompareFixture.model()
        let layout = m.layout(.delta, focusEntry: 0, options: SunburstOptions())
        let scale = m.deltaScale(for: layout, view: .delta)
        // Größte Änderung im ersten Ring: Downloads +100 MB.
        #expect(scale.reference == 100 * MB)
        let x = try entry(m, "Downloads/Xcode")
        #expect(scale.intensity(m.diff.delta(x)) == 1)
    }

    // MARK: Liste

    @Test("Detailliste: Kinder samt entfernten, sortierbar nach Δ, Vorher, Jetzt und Name")
    func sorting() throws {
        let m = CompareFixture.model()
        func names(_ s: CompareSort) -> [String] { m.children(of: 0, sortedBy: s).map { m.diff.name(of: $0) } }
        #expect(names(.byDeltaDescending) == ["Downloads", "Projekte", "Musik", "Filme"])
        #expect(names(CompareSort(key: .delta, ascending: true)) == ["Filme", "Musik", "Projekte", "Downloads"])
        #expect(names(CompareSort(key: .now, ascending: false)) == ["Downloads", "Projekte", "Musik", "Filme"])
        #expect(names(CompareSort(key: .before, ascending: false)) == ["Filme", "Downloads", "Musik", "Projekte"])
        #expect(names(CompareSort(key: .name, ascending: true)) == ["Downloads", "Filme", "Musik", "Projekte"])
        #expect(names(CompareSort(key: .name, ascending: false)) == ["Projekte", "Musik", "Filme", "Downloads"])
        // Gleichstand bei Δ: nach Name.
        let dl = try entry(m, "Downloads")
        let kids = m.children(of: dl, sortedBy: .byDeltaDescending).map { m.diff.name(of: $0) }
        #expect(kids == ["Xcode", "alt.zip"])
    }

    @Test("Sortierung umschalten: gleiche Spalte dreht die Richtung, neue Spalte beginnt sinnvoll")
    func sortToggle() {
        var s = CompareSort.byDeltaDescending
        s.toggle(.delta)
        #expect(s == CompareSort(key: .delta, ascending: true))
        s.toggle(.name)
        #expect(s == CompareSort(key: .name, ascending: true))
        s.toggle(.now)
        #expect(s == CompareSort(key: .now, ascending: false))
    }

    @Test("Breadcrumb und Elterneinträge")
    func ancestry() throws {
        let m = CompareFixture.model()
        let a = try entry(m, "Downloads/Xcode/a.xip")
        let chain = m.ancestors(of: a).map { m.diff.name(of: $0) }
        #expect(chain == ["home", "Downloads", "Xcode", "a.xip"])
        #expect(m.parent(of: 0) == nil)
        #expect(m.parent(of: a) == (try entry(m, "Downloads/Xcode")))
        #expect(m.isAncestor(try entry(m, "Downloads"), of: a))
        #expect(!m.isAncestor(try entry(m, "Musik"), of: a))
    }

    @Test("Logische Größe: Deltas und Bäume im logischen Modus")
    func logicalMode() throws {
        let m = CompareFixture.model(.logical)
        expectValidTree(m.union.tree)
        expectValidTree(m.growth.tree)
        #expect(m.growth.tree.root.logicalSize == 115 * MB)
        let layout = m.layout(.growth, focusEntry: 0, options: SunburstOptions(sizeMode: .logical))
        #expect(!layout.isEmpty)
    }

    @Test("Status-Bezeichnungen")
    func statusLabels() {
        #expect(DiffStatus.allCases.map(\.label) == ["neu", "entfernt", "gewachsen", "geschrumpft", "unverändert"])
        #expect(CompareViewMode.allCases.map(\.title) == ["Wachstum", "Delta-Färbung"])
    }

    @Test("Ohne Zuwachs ist das Wachstumslayout leer")
    func noGrowth() {
        let t = CompareFixture.oldTree()
        let s = Snapshot(metadata: SnapshotMetadata(rootPath: t.rootPath), tree: t)
        let m = CompareModel(diff: SnapshotDiff(old: s, new: s))
        #expect(m.layout(.growth, focusEntry: 0, options: SunburstOptions()).isEmpty)
        #expect(!m.layout(.delta, focusEntry: 0, options: SunburstOptions()).isEmpty)
        #expect(m.hasGrowth == false)
    }
}

// MARK: Kopfzeile

@Suite("Vergleich: Kopfzeile", .language("de"))
struct CompareHeadlineTests {
    let MB = CompareFixture.MB
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test("Volume-Wurzel: belegt, frei und nicht zugeordnet wie in der Spec")
    func volumeRoot() {
        let o = CompareFixture.volume(used: 400 * MB, unassigned: 10 * MB)
        let n = CompareFixture.volume(used: 438_200_000, unassigned: 14_100_000)
        let diff = CompareFixture.diff(oldVolume: o, newVolume: n)
        let h = CompareHeadline(diff: diff, comparesSnapshots: false, timeZone: berlin)
        let date = Self.format(CompareFixture.oldDate, berlin)
        #expect(h.text == "Seit \(date): belegt +38,2\u{A0}MB · frei \u{2212}38,2\u{A0}MB · davon nicht zugeordnet +4,1\u{A0}MB")
        #expect(h.parts.map(\.delta) == [38_200_000, -38_200_000, 4_100_000])
        #expect(h.parts.map(\.label) == ["belegt", "frei", "davon nicht zugeordnet"])
    }

    @Test("Ordner-Scan: Scan-Summe des Ordners, dazu belegt und frei des Volumes")
    func folder() {
        let o = CompareFixture.volume(used: 400 * MB)
        let n = CompareFixture.volume(used: 470 * MB)
        let diff = CompareFixture.diff(oldVolume: o, newVolume: n)
        let h = CompareHeadline(diff: diff, comparesSnapshots: false, timeZone: berlin)
        #expect(h.parts.map(\.label) == ["home", "Volume belegt", "frei"])
        #expect(h.parts[0].delta == diff.summary.scanDelta)
        #expect(h.parts[0].delta == 59 * 1_000_000) // +100 +15 −6 −50
        #expect(h.parts[1].text == "+70,0\u{A0}MB")
        #expect(h.parts[2].text == "\u{2212}70,0\u{A0}MB")
    }

    @Test("Ohne Volume-Kennzahlen nur die Scan-Summe")
    func noVolume() {
        let h = CompareHeadline(diff: CompareFixture.diff(), comparesSnapshots: false, timeZone: berlin)
        #expect(h.parts.map(\.label) == ["home"])
    }

    @Test("Zwei Snapshots: „Von … bis …“")
    func twoSnapshots() {
        let h = CompareHeadline(diff: CompareFixture.diff(), comparesSnapshots: true, timeZone: berlin)
        let a = Self.format(CompareFixture.oldDate, berlin), b = Self.format(CompareFixture.newDate, berlin)
        #expect(h.prefix == "Von \(a) bis \(b)")
    }

    @Test("Datumsformat ist deutsch und hängt von der Zeitzone ab")
    func dateFormat() {
        let d = Date(timeIntervalSince1970: 1_790_926_440) // 2026-10-02 07:34 UTC
        #expect(CompareHeadline.shortDate(d, timeZone: TimeZone(identifier: "UTC")!) == "02.10., 07:34")
        #expect(CompareHeadline.shortDate(d, timeZone: berlin) == "02.10., 09:34")
    }

    @Test("Warnung bei abweichenden Scan-Optionen wird durchgereicht")
    func warnings() {
        let diff = CompareFixture.diff(oldOptions: SnapshotScanOptions(includeHidden: false))
        let m = CompareModel(diff: diff)
        #expect(m.warningTexts.count == 1)
        #expect(m.warningTexts[0].contains("versteckte Dateien"))
        #expect(CompareFixture.model().warningTexts.isEmpty)
    }

    static func format(_ d: Date, _ tz: TimeZone) -> String { CompareHeadline.shortDate(d, timeZone: tz) }
}
