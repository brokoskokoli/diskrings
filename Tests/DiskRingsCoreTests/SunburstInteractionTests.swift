@testable import DiskRingsCore
import Foundation
import Testing

@Suite("SunburstGeometry")
struct SunburstGeometryTests {
    @Test("Innere Ringe sind breiter, Grenzen steigen bis zum Außenradius")
    func radii() {
        let g = SunburstGeometry(rings: 6, outerRadius: 300)
        #expect(g.radii.count == 7)
        #expect(abs(g.centerRadius - 66) < 1e-9)
        #expect(g.radii.last == 300)
        var lastWidth = Double.infinity
        for k in 1 ... 6 {
            let w = g.outerRadius(ofRing: k) - g.innerRadius(ofRing: k)
            #expect(w > 0 && w < lastWidth)
            lastWidth = w
        }
    }

    @Test("Ring zu Radius und gebrochene Grenzen")
    func ringLookup() {
        let g = SunburstGeometry(rings: 4, outerRadius: 200)
        #expect(g.ring(atRadius: 0) == 0)
        #expect(g.ring(atRadius: g.centerRadius - 0.01) == 0)
        #expect(g.ring(atRadius: g.centerRadius) == 1)
        #expect(g.ring(atRadius: g.radii[2]) == 3)
        #expect(g.ring(atRadius: 199.99) == 4)
        #expect(g.ring(atRadius: 200) == nil)
        #expect(g.ring(atRadius: -1) == nil)
        #expect(g.ring(atRadius: .nan) == nil)
        #expect(g.radius(atBoundary: 0) == g.centerRadius)
        #expect(g.radius(atBoundary: 2) == g.radii[2])
        #expect(abs(g.radius(atBoundary: 1.5) - (g.radii[1] + g.radii[2]) / 2) < 1e-9)
        #expect(g.radius(atBoundary: -1) == 0)
        #expect(g.radius(atBoundary: 5) > 200)
    }
}

@Suite("SunburstHitTester")
struct SunburstHitTesterTests {
    func setup() -> (ScanTree, SunburstLayout, SunburstHitTester) {
        let t = sampleTree()
        let l = SunburstLayout(tree: t)
        return (t, l, SunburstHitTester(layout: l, geometry: SunburstGeometry(rings: 6, outerRadius: 300)))
    }

    func point(_ g: SunburstGeometry, ring: Int, angle: Double) -> (Double, Double) {
        let r = (g.innerRadius(ofRing: ring) + g.outerRadius(ofRing: ring)) / 2
        return (r * sin(angle), -r * cos(angle))
    }

    @Test("Winkel: 0 oben, im Uhrzeigersinn")
    func angles() {
        #expect(SunburstHitTester.angle(dx: 0, dy: -1) == 0)
        #expect(abs(SunburstHitTester.angle(dx: 1, dy: 0) - .pi / 2) < 1e-12)
        #expect(abs(SunburstHitTester.angle(dx: 0, dy: 1) - .pi) < 1e-12)
        #expect(abs(SunburstHitTester.angle(dx: -1, dy: 0) - 1.5 * .pi) < 1e-12)
        // Knapp links von oben: kurz vor 2π, nie 2π selbst.
        let a = SunburstHitTester.angle(dx: -1e-12, dy: -1)
        #expect(a < 2 * .pi && a > 1.99 * .pi)
        #expect(SunburstHitTester.angle(dx: 0, dy: 0) == 0)
    }

    @Test("Mitte, Ringe, außerhalb")
    func basic() {
        let (t, l, h) = setup()
        #expect(h.hit(dx: 0, dy: 0) == .center)
        #expect(h.hit(dx: 10, dy: 10) == .center)
        #expect(h.hit(dx: 400, dy: 0) == .none)
        // Ring 1 bei 90°: a (0…216°).
        let (x, y) = point(h.geometry, ring: 1, angle: .pi / 2)
        guard case .arc(let i) = h.hit(dx: x, dy: y) else { Issue.record("kein Treffer"); return }
        #expect(t.name(of: l.arcs[i].nodeIndex) == "a")
        // Ring 2 bei 90°: a1.
        let (x2, y2) = point(h.geometry, ring: 2, angle: .pi / 2)
        guard case .arc(let j) = h.hit(dx: x2, dy: y2) else { Issue.record("kein Treffer"); return }
        #expect(t.name(of: l.arcs[j].nodeIndex) == "a1")
        // Ring 4 existiert im Layout nicht.
        let (x4, y4) = point(h.geometry, ring: 4, angle: .pi / 2)
        #expect(h.hit(dx: x4, dy: y4) == .none)
    }

    @Test("Randwinkel: Grenze gehört zum folgenden Arc, 0 und 2π")
    func edges() {
        let (t, l, h) = setup()
        let ring1 = l.ringRanges[0]
        let bStart = l.arcs[ring1.lowerBound + 1].startAngle
        #expect(h.hit(ring: 1, angle: bStart) == .arc(ring1.lowerBound + 1))
        #expect(h.hit(ring: 1, angle: bStart.nextDown) == .arc(ring1.lowerBound))
        #expect(h.hit(ring: 1, angle: 0) == .arc(0))
        #expect(h.hit(ring: 1, angle: 2 * .pi) == .arc(0)) // 2π ≙ 0
        #expect(h.hit(ring: 1, angle: (2 * .pi).nextDown) == .arc(ring1.upperBound - 1))
        #expect(h.hit(ring: 1, angle: -0.1) == .arc(ring1.upperBound - 1)) // negativ wird normalisiert
        #expect(h.hit(ring: 1, angle: .nan) == .none)
        #expect(h.hit(ring: 0, angle: 1) == .none)
        #expect(h.hit(ring: 99, angle: 1) == .none)
        // Lücke in Ring 2 (unter b, einer Datei) ergibt keinen Treffer.
        let bMid = l.arcs[ring1.lowerBound + 1].midAngle
        #expect(h.hit(ring: 2, angle: bMid) == .none)
        _ = t
    }

    @Test("Jeder Arc wird an seiner Mitte getroffen (Demo-Baum)")
    func everyArc() {
        let t = DemoTree.home()
        let l = SunburstLayout(tree: t, options: SunburstOptions(unassigned: 20_000_000_000))
        let g = SunburstGeometry(rings: 6, outerRadius: 400)
        let h = SunburstHitTester(layout: l, geometry: g)
        for (i, arc) in l.arcs.enumerated() where arc.span > 1e-12 {
            #expect(h.hit(ring: Int(arc.depth), angle: arc.midAngle) == .arc(i))
            let (x, y) = point(g, ring: Int(arc.depth), angle: arc.midAngle)
            #expect(h.hit(dx: x, dy: y) == .arc(i))
        }
    }

    @Test("„Nicht zugeordnet“ ist in allen Ringen treffbar")
    func unassignedAllRings() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t, options: SunburstOptions(unassigned: 1000))
        let g = SunburstGeometry(rings: 6, outerRadius: 300)
        let u = l.ringRanges[0].upperBound - 1
        #expect(l.arcs[u].kind == .unassigned)
        let angle = l.arcs[u].midAngle
        for ring in 1 ... 6 {
            let (x, y) = point(g, ring: ring, angle: angle)
            #expect(SunburstHitTester(layout: l, geometry: g).hit(dx: x, dy: y) == .arc(u))
        }
        let (x, y) = point(g, ring: 5, angle: angle)
        #expect(SunburstHitTester(layout: l, geometry: g, unassignedSpansAllRings: false).hit(dx: x, dy: y) == .none)
    }

    @Test("Leeres Layout: nur die Mitte")
    func empty() {
        let t = ScanTreeBuilder(rootName: "e").build(rootPath: "/e")
        let h = SunburstHitTester(layout: SunburstLayout(tree: t), geometry: SunburstGeometry(rings: 6, outerRadius: 100))
        #expect(h.hit(dx: 0, dy: 0) == .center)
        #expect(h.hit(dx: 50, dy: 0) == .none)
    }
}

@Suite("Palette")
struct PaletteTests {
    @Test("HSB ↔ RGB")
    func hsb() {
        let red = RGBColor(hue: 0, saturation: 1, brightness: 1)
        #expect(red.hex == "#FF0000")
        #expect(RGBColor(hue: 120, saturation: 1, brightness: 1).hex == "#00FF00")
        #expect(RGBColor(hue: 240, saturation: 1, brightness: 0.5).hex == "#000080")
        #expect(RGBColor(hue: 360 + 60, saturation: 1, brightness: 1).hex == "#FFFF00")
        let c = RGBColor(hue: 212, saturation: 0.6, brightness: 0.8)
        let (h, s, b) = c.hsb
        #expect(abs(h - 212) < 0.5 && abs(s - 0.6) < 0.01 && abs(b - 0.8) < 0.01)
        #expect(RGBColor(red: 2, green: -1, blue: 0.5).red == 1)
    }

    @Test("Ast: gleicher Ton je Ast, nach außen heller bzw. weniger gesättigt, Dateien gedämpft")
    func branchColors() {
        for appearance in PaletteAppearance.allCases {
            let p = Palette(scheme: .branch, appearance: appearance)
            var prev = p.branchColor(branchIndex: 0, depth: 1, isDirectory: true).hsb
            for d in 2 ... 10 {
                let c = p.branchColor(branchIndex: 0, depth: d, isDirectory: true).hsb
                #expect(abs(c.hue - prev.hue) < 1)
                #expect(c.saturation < prev.saturation || c.saturation <= 0.121)
                #expect(c.brightness >= prev.brightness)
                prev = c
            }
            let dir = p.branchColor(branchIndex: 2, depth: 2, isDirectory: true).hsb
            let file = p.branchColor(branchIndex: 2, depth: 2, isDirectory: false).hsb
            #expect(file.saturation < dir.saturation)
            // Benachbarte Äste haben deutlich verschiedene Töne.
            let h0 = p.branchColor(branchIndex: 0, depth: 1, isDirectory: true).hsb.hue
            let h1 = p.branchColor(branchIndex: 1, depth: 1, isDirectory: true).hsb.hue
            #expect(min(abs(h0 - h1), 360 - abs(h0 - h1)) > 60)
        }
    }

    @Test("Farben eines Layouts: Sammelsegment grau, Kinder im Ton des Asts")
    func layoutColors() {
        let t = sampleTree()
        let l = SunburstLayout(tree: t, options: SunburstOptions(unassigned: 500))
        for appearance in PaletteAppearance.allCases {
            let p = Palette(appearance: appearance)
            let colors = p.colors(for: l, tree: t)
            #expect(colors.count == l.arcs.count)
            for (i, a) in l.arcs.enumerated() {
                switch a.kind {
                case .aggregate: #expect(colors[i] == p.aggregateFill)
                case .unassigned: #expect(colors[i] == p.unassignedFill)
                case .remainder: #expect(colors[i] == p.remainderFill)
                case .node:
                    #expect(colors[i].hsb.saturation > 0.1)
                    if a.parentArc >= 0, a.isDirectory {
                        let ph = colors[Int(a.branch)].hsb.hue
                        #expect(min(abs(colors[i].hsb.hue - ph), 360 - abs(colors[i].hsb.hue - ph)) < 20)
                    }
                }
            }
            #expect(p.aggregateFill.hsb.saturation == 0)
        }
        #expect(Palette(appearance: .dark).background != Palette(appearance: .light).background)
    }

    @Test("Textfarbe mit ausreichendem Kontrast")
    func labelContrast() {
        for appearance in PaletteAppearance.allCases {
            let p = Palette(appearance: appearance)
            for bi in 0 ..< Palette.branchHues.count {
                for d in 1 ... 3 {
                    let fill = p.branchColor(branchIndex: bi, depth: d, isDirectory: true)
                    #expect(p.label(on: fill).contrast(to: fill) >= 4.5)
                }
            }
            #expect(p.primaryText.contrast(to: p.background) >= 7)
            #expect(p.secondaryText.contrast(to: p.background) >= 4.5)
        }
    }

    @Test("Dateityp-Kategorien und Farbschema „Dateityp“")
    func fileTypes() {
        #expect(FileTypeCategory.classify(name: "Urlaub.MOV") == .video)
        #expect(FileTypeCategory.classify(name: "a.heic") == .image)
        #expect(FileTypeCategory.classify(name: "x.tar.gz") == .archive)
        #expect(FileTypeCategory.classify(name: "Safari.app") == .application)
        #expect(FileTypeCategory.classify(name: "main.swift") == .code)
        #expect(FileTypeCategory.classify(name: "Rechnung.pdf") == .document)
        #expect(FileTypeCategory.classify(name: ".zshrc") == .other)
        #expect(FileTypeCategory.classify(name: "README") == .other)
        #expect(FileTypeCategory.classify(name: "ende.") == .other)
        #expect(Set(FileTypeCategory.allCases.map(\.label)).count == 8)

        var b = ScanTreeBuilder(rootName: "r")
        let app = b.directory("Foo.app", flags: .package)
        b.file("binary", size: 500, in: app)
        b.file("film.mp4", size: 400)
        let plain = b.directory("Ordner")
        b.file("notiz.txt", size: 100, in: plain)
        let t = b.build(rootPath: "/r")
        let l = SunburstLayout(tree: t)
        let p = Palette(scheme: .fileType, appearance: .light)
        let colors = p.colors(for: l, tree: t)
        func color(_ path: String) -> RGBColor { colors[l.arcIndex(ofNode: idx(t, path))!] }
        #expect(color("Foo.app") == p.categoryColor(.application))
        // Inhalt eines Pakets erbt die Kategorie (gedämpft als Datei).
        #expect(color("Foo.app/binary").hsb.hue.rounded() == p.categoryColor(.application).hsb.hue.rounded())
        #expect(color("Ordner") == p.neutralFolderColor(depth: 1))
        #expect(abs(color("Ordner/notiz.txt").hsb.hue - p.categoryColor(.document).hsb.hue) < 1)
        #expect(abs(color("film.mp4").hsb.hue - p.categoryColor(.video).hsb.hue) < 1)
    }
}

@Suite("LabelPlacement")
struct LabelPlacementTests {
    @Test("Tangential, radial oder gar nicht")
    func decide() {
        // Breites Segment im inneren Ring: tangential.
        #expect(LabelPlacement.decide(span: 1.5, innerRadius: 60, outerRadius: 110, textWidth: 60, textHeight: 14) == .tangential)
        // Schmales Segment, aber breiter Ring: radial.
        #expect(LabelPlacement.decide(span: 0.2, innerRadius: 100, outerRadius: 180, textWidth: 50, textHeight: 12) == .radial)
        // Winzig: keine Beschriftung.
        #expect(LabelPlacement.decide(span: 0.01, innerRadius: 100, outerRadius: 130, textWidth: 50, textHeight: 12) == .none)
        #expect(LabelPlacement.decide(span: 0, innerRadius: 100, outerRadius: 130, textWidth: 50, textHeight: 12) == .none)
        #expect(LabelPlacement.decide(span: 1, innerRadius: 100, outerRadius: 100, textWidth: 50, textHeight: 12) == .none)
    }

    @Test("Kürzen mit Auslassungszeichen")
    func truncate() {
        #expect(LabelPlacement.truncate("Library", maxCharacters: 10) == "Library")
        #expect(LabelPlacement.truncate("Application Support", maxCharacters: 8) == "Applica…")
        #expect(LabelPlacement.truncate("abc", maxCharacters: 1) == "…")
        #expect(LabelPlacement.truncate("abc", maxCharacters: 0) == "")
    }
}

@Suite("FullDiskAccess")
struct FullDiskAccessTests {
    @Test("Lesbarer Testort ergibt „erteilt“, fehlende ergeben „unbekannt“")
    func probe() throws {
        let f = try Fixture()
        defer { f.remove() }
        let readable = try f.file("lesbar", size: 1)
        #expect(FullDiskAccess.status(probing: [f.path("fehlt"), readable]) == .granted)
        #expect(FullDiskAccess.status(probing: [f.path("fehlt")]) == .unknown)
        #expect(FullDiskAccess.status(probing: []) == .unknown)
        // Ein Ordner ohne Rechte meldet EACCES → „verweigert“.
        let locked = try f.dir("gesperrt")
        _ = try f.file("gesperrt/innen", size: 1)
        chmod(locked, 0)
        defer { chmod(locked, 0o755) }
        #expect(FullDiskAccess.status(probing: [locked + "/innen"]) == .denied)
        #expect(FullDiskAccess.settingsURL.hasPrefix("x-apple.systempreferences:"))
    }
}
