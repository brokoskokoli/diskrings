import Foundation

/// Affine Abbildung eines Layout-Raums auf die Anzeige:
/// Winkel' = `angleScale` · Winkel + `angleOffset`, Ring' = Ring + `depthShift`.
public struct ZoomTransform: Sendable, Equatable {
    public var angleScale: Double
    public var angleOffset: Double
    public var depthShift: Double

    public init(angleScale: Double, angleOffset: Double, depthShift: Double) {
        self.angleScale = angleScale
        self.angleOffset = angleOffset
        self.depthShift = depthShift
    }

    public static let identity = ZoomTransform(angleScale: 1, angleOffset: 0, depthShift: 0)

    public func angle(_ a: Double) -> Double { angleScale * a + angleOffset }

    /// Erst `inner`, dann `self` anwenden.
    public func composed(after inner: ZoomTransform) -> ZoomTransform {
        ZoomTransform(angleScale: angleScale * inner.angleScale,
                      angleOffset: angleScale * inner.angleOffset + angleOffset,
                      depthShift: depthShift + inner.depthShift)
    }

    /// Abbildung, die den Winkelbereich [start, end] auf den vollen Kreis legt
    /// und die Tiefe um `depth` verringert (Hineinzoomen in diesen Bereich).
    public static func expanding(start: Double, end: Double, depth: Double) -> ZoomTransform {
        let s = 2 * Double.pi / (end - start)
        return ZoomTransform(angleScale: s, angleOffset: -start * s, depthShift: -depth)
    }

    /// Umkehrung von `expanding`: der volle Kreis wird auf [start, end] gestaucht.
    public static func contracting(start: Double, end: Double, depth: Double) -> ZoomTransform {
        ZoomTransform(angleScale: (end - start) / (2 * .pi), angleOffset: start, depthShift: depth)
    }

    /// Interpolation zwischen zwei Abbildungen. Interpoliert werden die Bilder
    /// von 0 und 2π sowie die Tiefe, jeweils linear; so wandern beide Kanten
    /// des gezoomten Bereichs gleichmäßig und ohne Rückwärtsbewegung.
    public static func interpolate(_ a: ZoomTransform, _ b: ZoomTransform, _ t: Double) -> ZoomTransform {
        let t = min(max(t, 0), 1)
        let s0 = a.angle(0) + (b.angle(0) - a.angle(0)) * t
        let e0 = a.angle(2 * .pi) + (b.angle(2 * .pi) - a.angle(2 * .pi)) * t
        return ZoomTransform(angleScale: (e0 - s0) / (2 * .pi), angleOffset: s0,
                             depthShift: a.depthShift + (b.depthShift - a.depthShift) * t)
    }
}

/// Ein Arc in einem Animationsbild: gebrochene Ringgrenzen (siehe
/// `SunburstGeometry.radius(atBoundary:)`), auf [0, 2π] beschnittene Winkel
/// und eine Deckkraft.
public struct DisplayArc: Sendable, Equatable {
    /// Arc aus dem Ziel-Layout (`true`) oder aus dem Ausgangs-Layout.
    public var isFromTarget: Bool
    public var arcIndex: Int
    public var startAngle: Double
    public var endAngle: Double
    public var innerBoundary: Double
    public var outerBoundary: Double
    public var opacity: Double
}

/// Übergang zwischen zwei Layouts desselben Baums (SPEC 5 „Zoom-Animation“).
///
/// Ist der neue Fokus ein Nachfahre des alten, wird hineingezoomt: Der
/// Winkelbereich des neuen Fokus im alten Bild wächst zum vollen Kreis, die
/// Ringe rücken nach innen. Beim Herauszoomen umgekehrt. Ohne
/// Vorfahrenbeziehung wird überblendet. Beide Layouts werden mit derselben
/// „Kamera“ gezeichnet; das alte blendet aus, das neue liegt darüber.
public struct ZoomTransition: Sendable {
    public enum Kind: Sendable, Equatable { case zoomIn, zoomOut, crossfade }

    public let from: SunburstLayout
    public let to: SunburstLayout
    public let kind: Kind
    /// Abbildung des Ziel-Layouts bei t = 0 (bei t = 1 ist es die Identität).
    public let targetStart: ZoomTransform
    /// Abbildung vom Raum des alten Layouts in den des neuen.
    public let fromToTarget: ZoomTransform

    public init(from: SunburstLayout, to: SunburstLayout, tree: ScanTree) {
        self.from = from
        self.to = to
        let opts = from.options
        if from.focus != to.focus,
           let span = SunburstLayout.angularSpan(of: to.focus, under: from.focus, tree: tree, options: opts),
           span.end - span.start > 1e-9 {
            kind = .zoomIn
            targetStart = .contracting(start: span.start, end: span.end, depth: Double(span.depth))
            fromToTarget = .expanding(start: span.start, end: span.end, depth: Double(span.depth))
        } else if from.focus != to.focus,
                  let span = SunburstLayout.angularSpan(of: from.focus, under: to.focus, tree: tree, options: to.options),
                  span.end - span.start > 1e-9 {
            kind = .zoomOut
            targetStart = .expanding(start: span.start, end: span.end, depth: Double(span.depth))
            fromToTarget = .contracting(start: span.start, end: span.end, depth: Double(span.depth))
        } else {
            kind = .crossfade
            targetStart = .identity
            fromToTarget = .identity
        }
    }

    /// Abbildung des Ziel-Layouts zum Zeitpunkt t (0…1).
    public func targetTransform(at t: Double) -> ZoomTransform {
        ZoomTransform.interpolate(targetStart, .identity, t)
    }

    /// Abbildung des Ausgangs-Layouts zum Zeitpunkt t (0…1).
    public func sourceTransform(at t: Double) -> ZoomTransform {
        targetTransform(at: t).composed(after: fromToTarget)
    }

    /// Alle sichtbaren Arcs zum Zeitpunkt t (0…1, ohne Easing): erst die des
    /// alten Layouts (ausblendend), dann die des neuen.
    public func frame(at t: Double, rings: Int) -> [DisplayArc] {
        let t = min(max(t, 0), 1)
        var out: [DisplayArc] = []
        out.reserveCapacity(from.arcs.count + to.arcs.count)
        let fade = kind == .crossfade
        if t < 1 {
            Self.append(from.arcs, transform: sourceTransform(at: t), opacity: 1 - t, target: false,
                        rings: rings, into: &out)
        }
        if t > 0 || !fade {
            Self.append(to.arcs, transform: targetTransform(at: t), opacity: fade ? t : 1, target: true,
                        rings: rings, into: &out)
        }
        return out
    }

    private static func append(
        _ arcs: [SunburstArc], transform tr: ZoomTransform, opacity: Double, target: Bool, rings: Int,
        into out: inout [DisplayArc]
    ) {
        let full = 2 * Double.pi
        for (i, arc) in arcs.enumerated() {
            let a0 = max(0, tr.angle(arc.startAngle))
            let a1 = min(full, tr.angle(arc.endAngle))
            guard a1 > a0 else { continue }
            let outer = Double(arc.depth) + tr.depthShift
            let inner = max(0, outer - 1)
            // Ganz in der Mitte verschwunden oder ganz außerhalb des Diagramms.
            guard outer > 0.001, inner < Double(rings) else { continue }
            // Arcs, die von außen hereinwandern, blenden über die Breite eines Rings ein.
            let edgeFade = min(1, max(0, Double(rings) - inner))
            out.append(DisplayArc(isFromTarget: target, arcIndex: i, startAngle: a0, endAngle: a1,
                                  innerBoundary: inner, outerBoundary: min(outer, Double(rings)),
                                  opacity: opacity * edgeFade))
        }
    }
}

/// Easing für die Zoom-Animation (sanft beschleunigen und abbremsen).
public enum ZoomEasing {
    public static func easeInOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
