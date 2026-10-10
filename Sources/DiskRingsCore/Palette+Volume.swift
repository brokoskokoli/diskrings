import Foundation

/// Farben der Segmente der Volume-Wurzel (Systemdaten, löschbar, frei), auch für
/// den Belegungsbalken auf dem Startbildschirm und in der Statusleiste.
extension Palette {
    /// Systemdaten: gedämpftes Violett, deutlich von Grau (frei, Sammelsegmente)
    /// und von den Ast-Farben unterscheidbar.
    public var systemFill: RGBColor {
        isDark ? RGBColor(hue: 262, saturation: 0.34, brightness: 0.60)
            : RGBColor(hue: 262, saturation: 0.30, brightness: 0.66)
    }

    /// Ein Teil der Systemdaten im zweiten Ring: derselbe Ton, heller und je
    /// Teil leicht verschoben, damit Nachbarn unterscheidbar bleiben.
    public func systemPartFill(index: Int) -> RGBColor {
        let shift = Double(index % 3) * 0.05
        return isDark ? RGBColor(hue: 262, saturation: 0.26 - shift, brightness: 0.66 + shift)
            : RGBColor(hue: 262, saturation: 0.22 - shift, brightness: 0.78 + shift)
    }

    /// Löschbar (purgeable): Türkis.
    public var purgeableFill: RGBColor {
        isDark ? RGBColor(hue: 178, saturation: 0.45, brightness: 0.62)
            : RGBColor(hue: 178, saturation: 0.42, brightness: 0.78)
    }

    /// Frei: neutrales Grau nahe am Hintergrund (im Dunkelmodus etwas heller als
    /// das Fenster), damit es als leeres Segment erkennbar ist.
    public var freeFill: RGBColor { isDark ? RGBColor(white: 0.25) : RGBColor(white: 0.93) }

    /// Farbe eines Segments der Volume-Wurzel; andere Arcs: Sammelsegment-Grau.
    public func volumeSegmentFill(_ arc: SunburstArc) -> RGBColor {
        switch arc.kind {
        case .system: systemFill
        case .systemPart: systemPartFill(index: Int(max(arc.part, 0)))
        case .purgeable: purgeableFill
        case .free: freeFill
        case .node, .aggregate, .remainder: aggregateFill
        }
    }
}
