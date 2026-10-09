@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Delta-Färbung und Intensitätsskala")
struct DeltaPaletteTests {
    static func isRed(_ c: RGBColor) -> Bool {
        let (h, s, _) = c.hsb
        return (h < 20 || h > 340) && s > 0.1
    }

    static func isGreen(_ c: RGBColor) -> Bool {
        let (h, s, _) = c.hsb
        return h > 90 && h < 170 && s > 0.1
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
        // Logarithmisch: ein Zehntel der Referenz ist deutlich sichtbar.
        #expect(s.intensity(100_000_000) > 0.6)
        // Referenz 0 wird zu 1 Byte (kein Teilen durch null).
        #expect(DeltaScale(reference: 0).intensity(5) == 1)
    }

    @Test("Gewachsen ist rot, geschrumpft grün, Intensität steigert die Sättigung", arguments: PaletteAppearance.allCases)
    func colors(appearance: PaletteAppearance) {
        let p = Palette(appearance: appearance)
        var lastRed = -1.0, lastGreen = -1.0
        for t in stride(from: 0.15, through: 1.0, by: 0.05) {
            let r = p.deltaColor(status: .grown, intensity: t)
            let g = p.deltaColor(status: .shrunk, intensity: t)
            #expect(Self.isRed(r), "\(r)")
            #expect(Self.isGreen(g), "\(g)")
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
        // Die Markierung für neue Elemente hebt sich von kräftigem Rot ab.
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

    func distance(_ a: RGBColor, _ b: RGBColor) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
