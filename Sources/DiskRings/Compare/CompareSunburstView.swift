import DiskRingsCore
import SwiftUI

/// Sunburst im Vergleichsmodus. Gezeichnet wird mit dem normalen
/// `SunburstRenderer` auf dem Wachstums- bzw. Vergleichsbaum; darüber kommen
/// die Markierungen (neu: Punkt, entfernt: gestrichelter Rand) und eine
/// eigene Mitte mit Zuwachs bzw. Δ. Keine Zoom-Animation.
struct CompareSunburstView: View {
    let state: AppState
    let session: CompareSession
    var interactive = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var systemDifferentiateWithoutColor
    @Environment(\.forcedAccessibility) private var forced
    private var differentiateWithoutColor: Bool { systemDifferentiateWithoutColor || forced.differentiateWithoutColor }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = session.layout
            let display = session.displayTree
            if layout.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "equal.circle").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(session.view == .growth ? L("compare.chart.noGrowth") : L("compare.chart.noData"))
                        .font(.headline)
                    if session.view == .growth {
                        Text(L("compare.chart.noGrowth.hint"))
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let geometry = SunburstView.geometry(for: size, rings: layout.options.maxRings)
                let palette = Palette(scheme: session.view == .growth ? state.prefs.paletteScheme : .branch,
                                      appearance: PaletteAppearance(colorScheme))
                let colors = session.colors(palette: palette)
                let hoverNode = session.hoverEntry.flatMap { display.node(forEntry: $0) }
                let selectedNode = session.selected.flatMap { display.node(forEntry: $0) }
                let input = SunburstRenderer.Input(
                    tree: display.tree, layout: layout, colors: colors, fromColors: nil, geometry: geometry,
                    palette: palette, hoverArc: session.hoverArc, hoverNode: hoverNode,
                    hoverCenter: session.hoverCenter, selected: selectedNode.map { [$0] } ?? [],
                    primarySelected: selectedNode,
                    focusIsRoot: layout.focus == ScanTree.rootIndex, showLabels: state.prefs.showLabels,
                    centerTitle: "", sizeMode: layout.options.sizeMode)
                let marks = Self.marks(session: session, layout: layout)
                let center = centerTexts(layout: layout, display: display)
                // Ohne Farbe unterscheiden: nur in der Delta-Färbung (dort trägt die Farbe den Status).
                let patterns = differentiateWithoutColor && session.view == .delta
                Canvas(opaque: false, rendersAsynchronously: false) { gc, canvasSize in
                    SunburstRenderer.draw(input, transition: nil, progress: nil, in: &gc, size: canvasSize)
                    CompareOverlayRenderer.draw(marks: marks, layout: layout, colors: colors, geometry: geometry,
                                                palette: palette, center: center, hoverCenter: session.hoverCenter,
                                                differentiateWithoutColor: patterns, in: &gc, size: canvasSize)
                }
                .contentShape(Rectangle())
                .modifier(CompareSunburstInteraction(state: state, session: session, geometry: geometry, size: size,
                                                     enabled: interactive))
                .overlay(alignment: .topLeading) {
                    CompareTooltip(session: session, size: size)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("compare.chart.accessibility", session.view.title, center.title))
                .accessibilityChildren {
                    ForEach(Array(layout.arcs(inRing: 1).enumerated()), id: \.offset) { _, arc in
                        if let e = session.model.entry(for: arc, view: session.view) {
                            Rectangle().accessibilityLabel(CompareText.accessibility(session.model, e))
                        }
                    }
                }
            }
        }
    }

    static func marks(session: CompareSession, layout: SunburstLayout) -> [DiffStatus?] {
        layout.arcs.map { session.model.status(of: $0, view: session.view) }
    }

    private func centerTexts(layout: SunburstLayout, display: CompareDisplayTree) -> CompareOverlayRenderer.Center {
        let model = session.model
        let e = display.entry(ofNode: layout.focus)
        let meta = model.diff.new.metadata
        let title = e == 0 && meta.volume?.unassigned != nil ? (meta.volume?.name ?? model.diff.name(of: 0))
            : model.diff.name(of: e)
        switch session.view {
        case .growth:
            return .init(title: title, value: "+" + ByteFormat.string(layout.focusSize), caption: L("compare.center.growth"),
                         valueIsGrowth: true)
        case .delta:
            let d = model.diff.delta(e, model.mode)
            return .init(title: title, value: ByteFormat.signed(d),
                         caption: L("compare.center.now", ByteFormat.string(model.diff.newSize(e, model.mode))),
                         valueIsGrowth: d > 0)
        }
    }
}

/// Zeichnet Markierungen und die Mitte über das normale Diagramm.
enum CompareOverlayRenderer {
    struct Center {
        let title: String
        let value: String
        let caption: String
        let valueIsGrowth: Bool
    }

    /// `differentiateWithoutColor`: Geschrumpftes zusätzlich schraffiert,
    /// Gewachsenes und Geschrumpftes mit „+“ bzw. „−“, wo Platz ist
    /// (Einstellung „Ohne Farbe unterscheiden“).
    static func draw(marks: [DiffStatus?], layout: SunburstLayout, colors: [DiskRingsCore.RGBColor],
                     geometry g: SunburstGeometry, palette: Palette, center info: Center, hoverCenter: Bool,
                     differentiateWithoutColor: Bool = false, in gc: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let removedStroke = Color(palette.removedStroke)
        for (i, arc) in layout.arcs.enumerated() where i < marks.count {
            guard let status = marks[i] else { continue }
            let ring = Int(arc.depth)
            let inner = g.innerRadius(ofRing: ring), outer = g.outerRadius(ofRing: ring)
            if differentiateWithoutColor, i < colors.count {
                drawColorIndependentMark(status, arc: arc, inner: inner, outer: outer, fill: colors[i], palette: palette,
                                         center: c, in: &gc, size: size)
            }
            switch status {
            case .removed:
                guard arc.span * outer > 3 else { continue }
                let path = SunburstRenderer.segment(center: c, inner: inner, outer: outer, start: arc.startAngle,
                                                    end: arc.endAngle)
                var ctx = gc
                ctx.clip(to: path)
                ctx.stroke(path, with: .color(removedStroke), style: StrokeStyle(lineWidth: 2.4, dash: [4, 3]))
            case .added:
                // Punkt nahe der Außenkante, nur wenn das Segment Platz hat.
                let r = outer - min(7, (outer - inner) / 3)
                guard arc.span * r > 9, outer - inner > 8, i < colors.count else { continue }
                let p = CGPoint(x: c.x + r * sin(arc.midAngle), y: c.y - r * cos(arc.midAngle))
                let d = 5.0
                gc.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                        with: .color(Color(palette.addedMarker(on: colors[i]))))
            default:
                continue
            }
        }
        drawCenter(info, geometry: g, palette: palette, hover: hoverCenter, focusIsRoot: layout.focus == 0,
                   at: c, in: &gc)
    }

    /// Schraffur für Geschrumpftes und „+“/„−“ nahe der Außenkante.
    private static func drawColorIndependentMark(_ status: DiffStatus, arc: SunburstArc, inner: Double, outer: Double,
                                                 fill: DiskRingsCore.RGBColor, palette: Palette, center c: CGPoint,
                                                 in gc: inout GraphicsContext, size: CGSize) {
        guard let mark = Palette.deltaMark(for: status) else { return }
        let ink = Color(palette.label(on: fill))
        if status == .shrunk, arc.span * outer > 3 {
            let path = SunburstRenderer.segment(center: c, inner: inner, outer: outer, start: arc.startAngle,
                                                end: arc.endAngle)
            var ctx = gc
            ctx.clip(to: path)
            var lines = Path()
            // Gegenläufig zur Schraffur von „Nicht zugeordnet“.
            var x = -size.height
            while x < size.width + size.height {
                lines.move(to: CGPoint(x: x + size.height, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += 6
            }
            ctx.stroke(lines, with: .color(ink.opacity(0.35)), lineWidth: 1)
        }
        let r = outer - min(8, (outer - inner) / 3)
        guard arc.span * r > 12, outer - inner > 12 else { return }
        let p = CGPoint(x: c.x + r * sin(arc.midAngle), y: c.y - r * cos(arc.midAngle))
        let text = gc.resolve(Text(mark).font(.system(size: 11, weight: .bold)).foregroundColor(ink))
        gc.draw(text, at: p, anchor: .center)
    }

    private static func drawCenter(_ info: Center, geometry g: SunburstGeometry, palette: Palette, hover: Bool,
                                   focusIsRoot: Bool, at c: CGPoint, in gc: inout GraphicsContext) {
        let r = g.centerRadius
        gc.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                with: .color(Color(hover ? palette.centerHoverFill : palette.centerFill)))
        let titleSize = max(10, min(15, r / 6))
        var title = gc.resolve(Text(info.title).font(.system(size: titleSize, weight: .semibold))
            .foregroundColor(Color(palette.primaryText)))
        var chars = info.title.count
        while chars > 4, title.measure(in: CGSize(width: 10_000, height: 100)).width > r * 1.6 {
            chars -= 1
            title = gc.resolve(Text(LabelPlacement.truncate(info.title, maxCharacters: chars))
                .font(.system(size: titleSize, weight: .semibold)).foregroundColor(Color(palette.primaryText)))
        }
        let accent = info.valueIsGrowth ? Color(palette.deltaTextColor(1)) : Color(palette.primaryText)
        let value = gc.resolve(Text(info.value).font(.system(size: max(11, min(16, r / 5.5)), weight: .bold)
            .monospacedDigit()).foregroundColor(accent))
        let caption = gc.resolve(Text(info.caption).font(.system(size: max(9, min(11, r / 8))))
            .foregroundColor(Color(palette.secondaryText)))
        let y0 = c.y - (focusIsRoot ? 4 : 0)
        gc.draw(title, at: CGPoint(x: c.x, y: y0 - 18), anchor: .center)
        gc.draw(value, at: CGPoint(x: c.x, y: y0 + 2), anchor: .center)
        gc.draw(caption, at: CGPoint(x: c.x, y: y0 + 20), anchor: .center)
        if !focusIsRoot, r > 40 {
            let up = gc.resolve(Text(Image(systemName: "arrow.up.circle")).font(.system(size: 13))
                .foregroundColor(Color(hover ? palette.primaryText : palette.secondaryText)))
            gc.draw(up, at: CGPoint(x: c.x, y: c.y - r * 0.62), anchor: .center)
        }
    }
}

/// Hover, Klick und Kontextmenü im Vergleichsdiagramm.
private struct CompareSunburstInteraction: ViewModifier {
    let state: AppState
    let session: CompareSession
    let geometry: SunburstGeometry
    let size: CGSize
    let enabled: Bool

    func hit(_ p: CGPoint) -> SunburstHit {
        SunburstHitTester(layout: session.layout, geometry: geometry)
            .hit(dx: p.x - size.width / 2, dy: p.y - size.height / 2)
    }

    /// Eintrag für das Kontextmenü: das Segment unter der Maus bzw. der Fokus (Mitte).
    private var contextEntry: Int32? {
        if session.hoverCenter { return session.focus }
        return session.hoverEntry
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): session.hoverDiagram(hit(p), at: p)
                    case .ended: session.hoverDiagram(.none, at: nil)
                    }
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { p in session.click(hit(p)) }
                .contextMenu {
                    if let e = contextEntry { CompareContextMenu(state: state, entry: e) }
                }
        } else {
            content
        }
    }
}

/// Tooltip: Name, Pfad, Vorher/Jetzt, Δ und Status.
private struct CompareTooltip: View {
    let session: CompareSession
    let size: CGSize
    /// Breite wächst mit der Textgröße.
    @ScaledMetric(relativeTo: .callout) private var width: CGFloat = 280

    var body: some View {
        if let loc = session.hoverLocation, let i = session.hoverArc, i < session.layout.arcs.count {
            let arc = session.layout.arcs[i]
            let x = min(max(8, loc.x + 16), max(8, size.width - width - 8))
            let y = loc.y + 18 + 100 > size.height ? loc.y - 110 : loc.y + 18
            VStack(alignment: .leading, spacing: 3) {
                content(arc)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .offset(x: x, y: max(4, y))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func content(_ arc: SunburstArc) -> some View {
        let model = session.model
        if let e = model.entry(for: arc, view: session.view) {
            let status = model.diff.status(e, model.mode)
            HStack(spacing: 5) {
                Image(systemName: statusSymbol(status)).foregroundStyle(statusColor(status))
                Text(model.diff.name(of: e)).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Text(model.diff.path(of: e)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .truncationMode(.middle)
            Text(CompareText.beforeNow(model, e)).font(.subheadline.monospacedDigit())
            HStack(spacing: 6) {
                let d = model.diff.delta(e, model.mode)
                Text("Δ " + ByteFormat.signed(d)).font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(deltaTextColor(d))
                Text(status.label).font(.subheadline).foregroundStyle(.secondary)
            }
            if session.view == .growth, arc.isDirectory {
                Text(L("compare.tooltip.folderGrowth", ByteFormat.string(arc.size))).font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            let title = arc.kind == .aggregate ? itemsText(Int(arc.itemCount))
                : (session.view == .growth ? L("compare.tooltip.growthWithoutEntries") : L("arc.remainder.title"))
            Text(title).font(.callout.weight(.semibold))
            Text(ByteFormat.string(arc.size)).font(.subheadline.monospacedDigit())
            Text(arc.kind == .aggregate ? L("arc.aggregate.detail")
                : L("compare.tooltip.smallFiles", ByteFormat.string(max(session.model.diff.minimumFileSize, 1))))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Texte zu einem Vergleichseintrag.
enum CompareText {
    static func beforeNow(_ m: CompareModel, _ e: Int32) -> String {
        let s = m.diff.status(e, m.mode)
        let before = s == .added ? "–" : ByteFormat.string(m.diff.oldSize(e, m.mode))
        let now = s == .removed ? "–" : ByteFormat.string(m.diff.newSize(e, m.mode))
        return L("compare.beforeNow", before, now)
    }

    static func accessibility(_ m: CompareModel, _ e: Int32) -> String {
        let s = m.diff.status(e, m.mode)
        return L("compare.entry.accessibility", m.diff.name(of: e), s.label, beforeNow(m, e), ByteFormat.signed(m.diff.delta(e, m.mode)))
    }
}
