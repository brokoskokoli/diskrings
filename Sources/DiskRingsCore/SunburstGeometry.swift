import Foundation

/// Radien der Ringe (SPEC 3.4 „Ringbreite“): eine Mittelscheibe, darum
/// `rings` Ringe, deren Breite nach außen um den Faktor `decay` abnimmt.
public struct SunburstGeometry: Sendable, Equatable {
    public let rings: Int
    public let outerRadius: Double
    /// Radiengrenzen: `radii[0]` ist der Radius der Mitte, `radii[k]` der
    /// Außenradius von Ring k, `radii[rings] == outerRadius`.
    public let radii: [Double]

    /// - Parameters:
    ///   - centerFraction: Radius der Mitte als Anteil am Außenradius.
    ///   - decay: Verhältnis der Breite von Ring k+1 zu Ring k (< 1: innen breiter).
    public init(rings: Int, outerRadius: Double, centerFraction: Double = 0.22, decay: Double = 0.84) {
        let rings = max(1, rings)
        self.rings = rings
        self.outerRadius = max(0, outerRadius)
        let center = self.outerRadius * min(max(centerFraction, 0), 0.9)
        var weights: [Double] = []
        var w = 1.0
        for _ in 0 ..< rings { weights.append(w); w *= decay }
        let sum = weights.reduce(0, +)
        var radii = [center]
        var r = center
        for wk in weights {
            r += (self.outerRadius - center) * wk / sum
            radii.append(r)
        }
        radii[rings] = self.outerRadius
        self.radii = radii
    }

    public var centerRadius: Double { radii[0] }

    public func innerRadius(ofRing ring: Int) -> Double { radii[min(max(ring - 1, 0), rings)] }
    public func outerRadius(ofRing ring: Int) -> Double { radii[min(max(ring, 0), rings)] }

    /// Radius der (gebrochenen) Ringgrenze `x`: 0 = Rand der Mitte, k = Außenrand
    /// von Ring k. Zwischenwerte werden linear interpoliert (für die
    /// Zoom-Animation); unter 0 schrumpft der Radius linear bis zur Mitte,
    /// über `rings` wächst er mit der Breite des äußersten Rings weiter.
    public func radius(atBoundary x: Double) -> Double {
        if x <= 0 { return max(0, centerRadius * (1 + x)) }
        if x >= Double(rings) {
            let last = radii[rings] - radii[rings - 1]
            return outerRadius + (x - Double(rings)) * last
        }
        let k = Int(x.rounded(.down))
        let f = x - Double(k)
        return radii[k] + (radii[k + 1] - radii[k]) * f
    }

    /// Ring zu einem Abstand von der Mitte: 0 = Mitte, 1…rings, `nil` außerhalb.
    public func ring(atRadius r: Double) -> Int? {
        guard r.isFinite, r >= 0 else { return nil }
        if r < centerRadius { return 0 }
        if r >= outerRadius { return nil }
        // Wenige Ringe: lineare Suche ist schneller als eine binäre.
        for k in 1 ... rings where r < radii[k] { return k }
        return nil
    }
}

/// Ergebnis eines Hit-Tests im Diagramm.
public enum SunburstHit: Sendable, Equatable {
    /// Mittelscheibe (aktueller Fokus).
    case center
    /// Index in `SunburstLayout.arcs`.
    case arc(Int)
    /// Kein Segment (außerhalb oder in einer Lücke).
    case none
}

/// Hit-Test über Polarkoordinaten (SPEC 5): Der Radius ergibt den Ring, eine
/// binäre Suche über die nach Winkel sortierten Arcs dieses Rings das Segment.
public struct SunburstHitTester: Sendable {
    public let layout: SunburstLayout
    public let geometry: SunburstGeometry

    public init(layout: SunburstLayout, geometry: SunburstGeometry) {
        self.layout = layout
        self.geometry = geometry
    }

    /// Winkel eines Punkts relativ zur Mitte in Bildschirmkoordinaten
    /// (y nach unten): 0 = oben, im Uhrzeigersinn steigend, Bereich [0, 2π).
    public static func angle(dx: Double, dy: Double) -> Double {
        if dx == 0, dy == 0 { return 0 }
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        if a >= 2 * .pi { a -= 2 * .pi }
        return a
    }

    /// Punkt relativ zur Mitte (Bildschirmkoordinaten, y nach unten).
    public func hit(dx: Double, dy: Double) -> SunburstHit {
        let r = (dx * dx + dy * dy).squareRoot()
        guard let ring = geometry.ring(atRadius: r) else { return .none }
        if ring == 0 { return .center }
        return hit(ring: ring, angle: Self.angle(dx: dx, dy: dy))
    }

    /// Arc in `ring` beim Winkel `angle` (Bogenmaß, 0 = oben, im Uhrzeigersinn).
    /// Ein Winkel genau auf einer Grenze gehört zum folgenden Arc.
    public func hit(ring: Int, angle: Double) -> SunburstHit {
        guard ring >= 1, ring <= layout.ringRanges.count, angle.isFinite else { return .none }
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        let range = layout.ringRanges[ring - 1]
        let arcs = layout.arcs
        // Letzter Arc mit startAngle <= a.
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if arcs[mid].startAngle <= a { lo = mid + 1 } else { hi = mid }
        }
        let idx = lo - 1
        guard idx >= range.lowerBound, a < arcs[idx].endAngle else { return .none }
        return .arc(idx)
    }
}
