import DiskRingsCore
import SwiftUI

/// Zeichnet das Diagramm in einen `GraphicsContext`. Winkel aus dem Layout
/// (0 = oben, im Uhrzeigersinn) werden in SwiftUI-Winkel (0 = rechts)
/// umgerechnet; in SwiftUI-Koordinaten (y nach unten) zeichnet
/// `addArc(clockwise: false)` optisch im Uhrzeigersinn.
enum SunburstRenderer {
    struct Input {
        let tree: ScanTree
        let layout: SunburstLayout
        let colors: [DiskRingsCore.RGBColor]
        let fromColors: [DiskRingsCore.RGBColor]?
        let geometry: SunburstGeometry
        let palette: Palette
        let hoverArc: Int?
        let hoverNode: Int32?
        let hoverCenter: Bool
        let selected: Int32?
        let focusIsRoot: Bool
        let showLabels: Bool
        let centerTitle: String
        let sizeMode: SizeMode
    }

    static func draw(_ input: Input, transition: ZoomTransition?, progress: Double?, in gc: inout GraphicsContext,
                     size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let g = input.geometry
        let palette = input.palette
        let separator = Color(palette.separator)

        if let transition, let t = progress, t < 1 {
            // Animationsbild: beide Layouts mit derselben „Kamera“.
            for d in transition.frame(at: t, rings: g.rings) {
                let arc = d.isFromTarget ? transition.to.arcs[d.arcIndex] : transition.from.arcs[d.arcIndex]
                let colors = d.isFromTarget ? input.colors : (input.fromColors ?? input.colors)
                guard d.arcIndex < colors.count else { continue }
                var inner = g.radius(atBoundary: d.innerBoundary)
                let outer = arc.kind == .unassigned && d.outerBoundary >= 1
                    ? g.radius(atBoundary: Double(g.rings)) : g.radius(atBoundary: d.outerBoundary)
                if d.innerBoundary <= 0 { inner = g.centerRadius * max(0, d.outerBoundary) }
                let path = segment(center: center, inner: inner, outer: outer, start: d.startAngle, end: d.endAngle)
                gc.fill(path, with: .color(Color(colors[d.arcIndex]).opacity(d.opacity)))
                gc.stroke(path, with: .color(separator.opacity(d.opacity)), lineWidth: 0.75)
            }
            drawCenter(input, center: center, in: &gc, alpha: 1)
            return
        }

        let layout = input.layout
        let arcs = layout.arcs
        let highlighted = highlightSet(input)
        let dimOthers = !highlighted.isEmpty
        var selectedPath: Path?
        var hoverPath: Path?
        for (i, arc) in arcs.enumerated() {
            let inner = g.innerRadius(ofRing: Int(arc.depth))
            let outer = arc.kind == .unassigned ? g.outerRadius : g.outerRadius(ofRing: Int(arc.depth))
            let path = segment(center: center, inner: inner, outer: outer, start: arc.startAngle, end: arc.endAngle)
            var color = input.colors[i]
            if highlighted.contains(i) {
                color = palette.highlighted(color)
            } else if dimOthers, highlighted.first.map({ arcs[$0].branch != arc.branch }) ?? false {
                color = color.mixed(with: palette.background, 0.25)
            }
            gc.fill(path, with: .color(Color(color)))
            if arc.kind == .unassigned { drawHatching(path, color: color, palette: palette, in: &gc, size: size) }
            if arc.span * outer > 1.2 { gc.stroke(path, with: .color(separator), lineWidth: 0.75) }
            if i == input.hoverArc || (arc.kind == .node && arc.nodeIndex == input.hoverNode) { hoverPath = path }
            if arc.kind == .node, arc.nodeIndex == input.selected { selectedPath = path }
        }
        if let p = selectedPath {
            gc.stroke(p, with: .color(.accentColor), lineWidth: 2.5)
        }
        if let p = hoverPath {
            gc.stroke(p, with: .color(Color(palette.primaryText).opacity(0.55)), lineWidth: 1.5)
        }
        if input.showLabels { drawLabels(input, center: center, in: &gc) }
        drawCenter(input, center: center, in: &gc, alpha: 1)
    }

    /// Hervorgehobene Arcs: der unter der Maus bzw. der zum Knoten aus der Liste.
    private static func highlightSet(_ input: Input) -> [Int] {
        if let i = input.hoverArc { return [i] }
        if let n = input.hoverNode, let i = input.layout.arcIndex(ofNode: n) { return [i] }
        return []
    }

    static func segment(center c: CGPoint, inner: Double, outer: Double, start: Double, end: Double) -> Path {
        var p = Path()
        let s = Angle.radians(start - .pi / 2), e = Angle.radians(end - .pi / 2)
        if end - start >= 2 * .pi - 1e-9 {
            // Voller Ring: zwei Kreise mit Even-Odd-Füllung vermeiden die Naht.
            p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
            if inner > 0 {
                p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
            }
            return p.normalized(eoFill: true)
        }
        p.addArc(center: c, radius: outer, startAngle: s, endAngle: e, clockwise: false)
        if inner > 0 {
            p.addArc(center: c, radius: inner, startAngle: e, endAngle: s, clockwise: true)
        } else {
            p.addLine(to: c)
        }
        p.closeSubpath()
        return p
    }

    private static func drawHatching(_ path: Path, color: DiskRingsCore.RGBColor, palette: Palette, in gc: inout GraphicsContext,
                                     size: CGSize) {
        var ctx = gc
        ctx.clip(to: path)
        let stripe = Color(palette.background).opacity(palette.appearance == .dark ? 0.18 : 0.22)
        var lines = Path()
        let extent = size.width + size.height
        var x = -size.height
        while x < extent {
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x + size.height, y: size.height))
            x += 7
        }
        ctx.stroke(lines, with: .color(stripe), lineWidth: 2)
    }

    // MARK: Mitte

    private static func drawCenter(_ input: Input, center c: CGPoint, in gc: inout GraphicsContext, alpha: Double) {
        let r = input.geometry.centerRadius
        let palette = input.palette
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        gc.fill(circle, with: .color(Color(input.hoverCenter ? palette.centerHoverFill : palette.centerFill)))
        let size = input.tree.node(input.layout.focus).size(input.sizeMode)
        let maxWidth = r * 1.6
        let titleFont = Font.system(size: max(10, min(15, r / 6)), weight: .semibold)
        let title = fitted(input.centerTitle, font: titleFont, maxWidth: maxWidth, in: gc)
        let sizeText = gc.resolve(Text(ByteFormat.string(size))
            .font(.system(size: max(10, min(13, r / 7))).monospacedDigit())
            .foregroundStyle(Color(palette.secondaryText)))
        let hasUp = !input.focusIsRoot
        let titleY = c.y - (hasUp ? 4 : 0) - 8
        gc.draw(title, at: CGPoint(x: c.x, y: titleY), anchor: .center)
        gc.draw(sizeText, at: CGPoint(x: c.x, y: titleY + 18), anchor: .center)
        if hasUp, r > 40 {
            let up = gc.resolve(Text(Image(systemName: "arrow.up.circle"))
                .font(.system(size: 13))
                .foregroundStyle(Color(input.hoverCenter ? palette.primaryText : palette.secondaryText)))
            gc.draw(up, at: CGPoint(x: c.x, y: c.y - r * 0.55), anchor: .center)
        }
    }

    /// Text, auf `maxWidth` gekürzt.
    private static func fitted(_ s: String, font: Font, maxWidth: Double, in gc: GraphicsContext,
                               color: Color? = nil) -> GraphicsContext.ResolvedText {
        func resolve(_ str: String) -> GraphicsContext.ResolvedText {
            var t = Text(str).font(font)
            if let color { t = t.foregroundColor(color) }
            return gc.resolve(t)
        }
        var text = resolve(s)
        var chars = s.count
        while chars > 2, text.measure(in: CGSize(width: 10_000, height: 100)).width > maxWidth {
            chars = min(chars - 1, Int(Double(chars) * maxWidth / text.measure(in: CGSize(width: 10_000, height: 100)).width) + 1)
            text = resolve(LabelPlacement.truncate(s, maxCharacters: chars))
        }
        return text
    }

    // MARK: Beschriftung

    private static func drawLabels(_ input: Input, center c: CGPoint, in gc: inout GraphicsContext) {
        let g = input.geometry
        let layout = input.layout
        var drawn = 0
        for (i, arc) in layout.arcs.enumerated() where arc.kind == .node || arc.kind == .unassigned {
            if drawn >= 160 { break }
            let ring = Int(arc.depth)
            let inner = g.innerRadius(ofRing: ring), outer = g.outerRadius(ofRing: ring)
            // Schnelle Vorprüfung: zu kleine Segmente gar nicht erst messen.
            if arc.span * outer < 22 || outer - inner < 11 { continue }
            let fontSize: Double = ring == 1 ? 12 : (ring == 2 ? 11 : 10)
            let font = Font.system(size: fontSize, weight: ring == 1 ? .medium : .regular)
            let name = arc.kind == .unassigned ? "Nicht zugeordnet" : input.tree.name(of: arc.nodeIndex)
            let textColor = Color(input.palette.label(on: input.colors[i]))
            let full = gc.resolve(Text(name).font(font).foregroundColor(textColor))
            let m = full.measure(in: CGSize(width: 10_000, height: 100))
            let midR = (inner + outer) / 2
            var placement = LabelPlacement.decide(span: arc.span, innerRadius: inner, outerRadius: outer,
                                                  textWidth: m.width, textHeight: m.height)
            var text = full
            if placement == .none {
                // Gekürzt versuchen: in einer Schleife kürzen, bis der Text passt
                // (mindestens 4 sichtbare Zeichen plus „…“). Startwert aus dem
                // verfügbaren Platz geschätzt, damit es meist nur wenige Schritte sind.
                let avail = max(2 * (midR - m.height / 2) * sin(min(arc.span, .pi) / 2) - 8, outer - inner - 8)
                var visible = min(name.count - 1, Int(Double(name.count) * avail / max(m.width, 1)))
                while visible >= 4 {
                    text = gc.resolve(Text(LabelPlacement.truncate(name, maxCharacters: visible + 1)).font(font)
                        .foregroundColor(textColor))
                    let m2 = text.measure(in: CGSize(width: 10_000, height: 100))
                    placement = LabelPlacement.decide(span: arc.span, innerRadius: inner, outerRadius: outer,
                                                      textWidth: m2.width, textHeight: m2.height)
                    if placement != .none { break }
                    visible -= max(1, visible / 8)
                }
            }
            guard placement != .none else { continue }
            let mid = arc.midAngle
            var ctx = gc
            ctx.translateBy(x: c.x, y: c.y)
            switch placement {
            case .tangential:
                // Untere Hälfte um 180° drehen, damit der Text nicht kopfsteht.
                let bottom = mid > .pi / 2 && mid < 1.5 * .pi
                ctx.rotate(by: .radians(bottom ? mid + .pi : mid))
                ctx.draw(text, at: CGPoint(x: 0, y: bottom ? midR : -midR), anchor: .center)
            case .radial:
                let left = mid > .pi
                ctx.rotate(by: .radians(left ? mid + .pi / 2 : mid - .pi / 2))
                ctx.draw(text, at: CGPoint(x: left ? -midR : midR, y: 0), anchor: .center)
            case .none:
                break
            }
            drawn += 1
        }
    }
}
