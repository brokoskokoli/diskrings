@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Delta-Färbung und Intensitätsskala")
struct DeltaPaletteTests {
    static func isOrange(_ c: RGBColor) -> Bool {
        let (h, s, _) = c.hsb
        return h > 18 && h < 45 && s > 0.1
    }

    static func isBlue(_ c: RGBColor) -> Bool {
        let (h, s, _) = c.hsb
        return h > 195 && h < 235 && s > 0.1
    }

    @Test("Skala: 0 ohne Delta, 1 ab der Referenz, monoton, Mindestintensität")
    func scale() {
        let s = DeltaScale(reference: 1_000_000_000)
        #expect(s.intensity(0) == 0)
        #expect(s.intensity(1_000_000_000) == 1)
        #expect(s.intensity(5_000_000_000) == 1)
        #expect(s.intensity(-1_000_000_000) == 1)
        #expect(s.intensity(1) >= DeltaScale.minimumIntensity)
        var last = 0.0
        for d in [1, 1_000, 1_000_000, 10_000_000, 100_000_000, 500_000_000, 999_999_999] as [Int64] {
            let v = s.intensity(d)
            #expect(v > last)
            #expect(v <= 1)
            #expect(s.intensity(-d) == v) // symmetrisch
            last = v
        }
        // Wurzelskala: ein Zehntel der Referenz ist deutlich sichtbar, ein
        // Fünftel klar schwächer als das Ganze.
        #expect(s.intensity(100_000_000) > 0.4)
        #expect(s.intensity(200_000_000) < 0.6)
        // Referenz 0 wird zu 1 Byte (kein Teilen durch null).
        #expect(DeltaScale(reference: 0).intensity(5) == 1)
    }

    @Test("Gewachsen ist orange, geschrumpft blau, Intensität steigert die Sättigung", arguments: PaletteAppearance.allCases)
    func colors(appearance: PaletteAppearance) {
        let p = Palette(appearance: appearance)
        var lastRed = -1.0, lastGreen = -1.0
        for t in stride(from: 0.15, through: 1.0, by: 0.05) {
            let r = p.deltaColor(status: .grown, intensity: t)
            let g = p.deltaColor(status: .shrunk, intensity: t)
            #expect(Self.isOrange(r), "\(r)")
            #expect(Self.isBlue(g), "\(g)")
            // Abstand zum Hintergrund wächst mit der Intensität.
            let dr = distance(r, p.background), dg = distance(g, p.background)
            #expect(dr > lastRed)
            #expect(dg > lastGreen)
            lastRed = dr
            lastGreen = dg
            // Beschriftung bleibt lesbar.
            #expect(p.label(on: r).contrast(to: r) >= 4.5)
            #expect(p.label(on: g).contrast(to: g) >= 4.5)
        }
        // Neu wie gewachsen gefärbt.
        #expect(p.deltaColor(status: .added, intensity: 0.7) == p.deltaColor(status: .grown, intensity: 0.7))
        #expect(p.deltaColor(status: .removed, intensity: 1) == p.removedFill)
        #expect(p.deltaColor(status: .unchanged, intensity: 0) == p.unchangedFill)
        // Grau und neutral.
        #expect(p.unchangedFill.hsb.saturation < 0.08)
        #expect(p.removedFill.hsb.saturation < 0.08)
        #expect(p.removedFill != p.unchangedFill)
        // Die Linie entfernter Elemente hebt sich von der Füllung ab.
        #expect(p.removedStroke.contrast(to: p.removedFill) >= 2)
        // Die Markierung für neue Elemente hebt sich von kräftigem Orange ab.
        let strong = p.deltaColor(status: .added, intensity: 1)
        #expect(p.addedMarker(on: strong).contrast(to: strong) >= 3)
    }

    @Test("Legendenverlauf: von schwach nach kräftig")
    func legend() {
        let p = Palette()
        let stops = p.deltaLegendStops(status: .grown, count: 5)
        #expect(stops.count == 5)
        #expect(stops.first == p.deltaColor(status: .grown, intensity: DeltaScale.minimumIntensity))
        #expect(stops.last == p.deltaColor(status: .grown, intensity: 1))
    }

    // MARK: Farbenblindheit (Befund: nur Rot/Grün unterschied Zuwachs und Rückgang)

    /// Simulation nach Machado et al. (2009), Schweregrad 1, in linearem sRGB.
    static let deuteranopia = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413],
                               [-0.011820, 0.042940, 0.968881]]
    static let protanopia = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216],
                             [-0.003882, -0.048116, 1.051998]]

    static func simulate(_ c: RGBColor, _ m: [[Double]]) -> RGBColor {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func enc(_ v: Double) -> Double {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        let l = [lin(c.red), lin(c.green), lin(c.blue)]
        let o = m.map { row in enc(row[0] * l[0] + row[1] * l[1] + row[2] * l[2]) }
        return RGBColor(red: o[0], green: o[1], blue: o[2])
    }

    @Test("Zuwachs und Rückgang bleiben bei Rot-Grün-Schwäche unterscheidbar", arguments: PaletteAppearance.allCases)
    func colorBlindSafe(appearance: PaletteAppearance) {
        let p = Palette(appearance: appearance)
        for t in stride(from: 0.15, through: 1.0, by: 0.05) {
            let g = p.deltaColor(status: .grown, intensity: t)
            let s = p.deltaColor(status: .shrunk, intensity: t)
            let normal = distance(g, s)
            for m in [Self.deuteranopia, Self.protanopia] {
                #expect(distance(Self.simulate(g, m), Self.simulate(s, m)) >= 0.7 * normal, "t = \(t)")
            }
        }
        // Gegenprobe: das frühere Rot/Grün fällt bei Deuteranopie durch.
        let red = RGBColor(hue: 4, saturation: 0.82, brightness: 0.88)
        let green = RGBColor(hue: 142, saturation: 0.72, brightness: 0.75)
        #expect(distance(Self.simulate(red, Self.deuteranopia), Self.simulate(green, Self.deuteranopia))
            < 0.7 * distance(red, green))
    }

    @Test("Textfarben für Δ: orange/blau, lesbar auf Fenster- und Listenhintergrund", arguments: PaletteAppearance.allCases)
    func textColors(appearance: PaletteAppearance) {
        let p = Palette(appearance: appearance)
        let up = p.deltaTextColor(1), down = p.deltaTextColor(-1)
        #expect(Self.isOrange(up), "\(up)")
        #expect(Self.isBlue(down), "\(down)")
        #expect(p.deltaTextColor(0) == p.secondaryText)
        #expect(p.deltaTextColor(.max) == up && p.deltaTextColor(.min) == down)
        // Hintergrund der Listen: weiß bzw. Fenstergrau (hell), fast schwarz bzw. Dunkelgrau (dunkel).
        let backgrounds = appearance == .dark ? [p.background, RGBColor(white: 0.17)] : [p.background, RGBColor(white: 0.93)]
        for bg in backgrounds {
            #expect(up.contrast(to: bg) >= 4.5, "\(up) auf \(bg)")
            #expect(down.contrast(to: bg) >= 4.5, "\(down) auf \(bg)")
        }
    }

    @Test("Markierung ohne Farbe: + gewachsen, − geschrumpft")
    func marks() {
        #expect(Palette.deltaMark(for: .grown) == "+")
        #expect(Palette.deltaMark(for: .shrunk) == "\u{2212}")
        #expect(Palette.deltaMark(for: .added) == nil) // hat schon den Punkt
        #expect(Palette.deltaMark(for: .removed) == nil) // gestrichelt
        #expect(Palette.deltaMark(for: .unchanged) == nil)
    }

    func distance(_ a: RGBColor, _ b: RGBColor) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
