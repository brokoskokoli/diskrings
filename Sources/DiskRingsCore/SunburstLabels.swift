import Foundation

/// Platzierung einer Beschriftung in einem Segment (SPEC 3.4 „Beschriftung“).
public enum LabelPlacement: Sendable, Equatable {
    /// Entlang des Bogens (Bogenlänge auf dem mittleren Radius reicht für den Text).
    case tangential
    /// Entlang des Radius (Segment schmal, aber der Ring breit genug).
    case radial
    case none

    /// - Parameters:
    ///   - span: Winkel des Segments (Bogenmaß).
    ///   - innerRadius, outerRadius: Radien des Rings.
    ///   - textWidth, textHeight: Maße des Texts.
    ///   - padding: Rand zu den Segmentkanten.
    public static func decide(
        span: Double, innerRadius: Double, outerRadius: Double, textWidth: Double, textHeight: Double,
        padding: Double = 4
    ) -> LabelPlacement {
        guard span > 0, outerRadius > innerRadius, textWidth > 0 else { return .none }
        let mid = (innerRadius + outerRadius) / 2
        let ringWidth = outerRadius - innerRadius
        // Tangential: Text liegt gerade auf dem mittleren Radius; die Sehne an
        // der Innenkante des Textbands muss die Textbreite fassen.
        let innerText = mid - textHeight / 2
        if ringWidth >= textHeight + padding, innerText > 0 {
            let chord = 2 * innerText * sin(min(span, .pi) / 2)
            if chord >= textWidth + 2 * padding { return .tangential }
        }
        // Radial: Text liegt entlang des Radius; die Segmentbreite an der
        // Innenkante muss die Texthöhe fassen.
        if ringWidth >= textWidth + 2 * padding {
            let chord = 2 * innerRadius * sin(min(span, .pi) / 2)
            if chord >= textHeight + padding { return .radial }
        }
        return .none
    }

    /// Kürzt einen Namen auf höchstens `maxCharacters` Zeichen (mit „…“).
    public static func truncate(_ name: String, maxCharacters: Int) -> String {
        guard maxCharacters >= 1 else { return "" }
        guard name.count > maxCharacters else { return name }
        if maxCharacters == 1 { return "…" }
        return String(name.prefix(maxCharacters - 1)) + "…"
    }
}
