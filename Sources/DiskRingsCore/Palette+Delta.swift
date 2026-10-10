import Foundation

/// Intensitätsskala der Delta-Färbung (SPEC 3.9: „die Intensität richtet
/// sich nach der Größe des Deltas“).
///
/// Wurzelskala zwischen einer Mindestintensität (jede Änderung ist
/// sichtbar) und 1 (ab `reference`). Die Wurzel hebt kleine Änderungen an,
/// unterscheidet aber noch deutlich zwischen einem Fünftel und dem Ganzen
/// (eine logarithmische Skala ließ in der Vorschau fast alle gewachsenen
/// Ordner gleich kräftig erscheinen).
public struct DeltaScale: Sendable, Equatable {
    /// Intensität der kleinsten Änderung (> 0 Byte).
    public static let minimumIntensity = 0.15
    /// Betrag, ab dem die volle Intensität erreicht ist (mindestens 1 Byte).
    public let reference: UInt64

    public init(reference: UInt64) {
        self.reference = max(reference, 1)
    }

    /// 0 ohne Änderung, sonst `minimumIntensity` … 1 (symmetrisch im Vorzeichen).
    public func intensity(_ delta: Int64) -> Double {
        let m = delta.magnitude
        if m == 0 { return 0 }
        if m >= reference { return 1 }
        let t = (Double(m) / Double(reference)).squareRoot()
        return Self.minimumIntensity + (1 - Self.minimumIntensity) * min(max(t, 0), 1)
    }
}

/// Farben des Vergleichsmodus (SPEC 3.9): Orange = gewachsen, Blau =
/// geschrumpft, Intensität nach Delta; neue Elemente wie gewachsene (dazu
/// eine Markierung), entfernte hellgrau und gestrichelt, unveränderte grau.
///
/// Abweichung von der Spec (dort Rot/Grün): Orange/Blau bleibt auch bei
/// Rot-Grün-Schwäche unterscheidbar (siehe dev/DECISIONS.md).
extension Palette {
    /// Farbton für Zuwachs (Orange) und Rückgang (Blau), in Grad.
    public static let growthHue = 28.0
    public static let shrinkHue = 214.0

    /// Unveränderte Elemente: neutrales Grau.
    public var unchangedFill: RGBColor { isDark ? RGBColor(white: 0.33) : RGBColor(white: 0.86) }
    /// Entfernte Elemente: sehr helles bzw. sehr dunkles Grau (dazu gestrichelter Rand).
    public var removedFill: RGBColor { isDark ? RGBColor(white: 0.21) : RGBColor(white: 0.95) }
    /// Gestrichelter Rand entfernter Elemente.
    public var removedStroke: RGBColor { isDark ? RGBColor(white: 0.62) : RGBColor(white: 0.45) }

    /// Markierung neuer Elemente (Punkt im Segment), kontrastreich zur Füllung.
    public func addedMarker(on fill: RGBColor) -> RGBColor { label(on: fill) }

    /// Farbe eines Elements nach Status und Intensität (0…1, siehe `DeltaScale`).
    public func deltaColor(status: DiffStatus, intensity: Double) -> RGBColor {
        let t = intensity.clamped01
        switch status {
        case .unchanged: return unchangedFill
        case .removed: return removedFill
        case .grown, .added:
            return isDark
                ? RGBColor(hue: Self.growthHue, saturation: 0.35 + 0.45 * t, brightness: 0.38 + 0.50 * t)
                : RGBColor(hue: Self.growthHue, saturation: 0.10 + 0.72 * t, brightness: 0.98 - 0.10 * t)
        case .shrunk:
            return isDark
                ? RGBColor(hue: Self.shrinkHue, saturation: 0.35 + 0.40 * t, brightness: 0.34 + 0.46 * t)
                : RGBColor(hue: Self.shrinkHue, saturation: 0.10 + 0.62 * t, brightness: 0.97 - 0.22 * t)
        }
    }

    /// Textfarbe für Δ-Werte (Liste, Tooltip, Mitte): kräftiges Orange bzw.
    /// Blau mit mindestens 4,5 : 1 Kontrast zum Hintergrund; 0 neutral.
    public func deltaTextColor(_ delta: Int64) -> RGBColor {
        if delta == 0 { return secondaryText }
        if delta > 0 {
            return isDark ? RGBColor(red: 1.0, green: 0.62, blue: 0.30) : RGBColor(red: 0.64, green: 0.30, blue: 0.0)
        }
        return isDark ? RGBColor(red: 0.45, green: 0.68, blue: 1.0) : RGBColor(red: 0.0, green: 0.36, blue: 0.75)
    }

    /// Zeichen im Segment, wenn Farben nicht unterscheiden sollen
    /// („Ohne Farbe unterscheiden“): „+“ gewachsen, „−“ geschrumpft. Neue
    /// (Punkt) und entfernte Elemente (gestrichelt) sind schon ohne Farbe erkennbar.
    public static func deltaMark(for status: DiffStatus) -> String? {
        switch status {
        case .grown: "+"
        case .shrunk: "\u{2212}"
        case .added, .removed, .unchanged: nil
        }
    }

    /// Farbverlauf für die Legende, von der Mindest- bis zur vollen Intensität.
    public func deltaLegendStops(status: DiffStatus, count: Int) -> [RGBColor] {
        let n = max(count, 2)
        let lo = DeltaScale.minimumIntensity
        return (0 ..< n).map { deltaColor(status: status, intensity: lo + (1 - lo) * Double($0) / Double(n - 1)) }
    }
}
