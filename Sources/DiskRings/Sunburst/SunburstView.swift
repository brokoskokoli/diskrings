import AppKit
import DiskRingsCore
import SwiftUI

/// Sunburst-Diagramm (SPEC 3.4, 5): Canvas-Rendering, Hover mit Tooltip,
/// Klick-Zoom mit Animation, Klick auf die Mitte geht nach oben.
struct SunburstView: View {
    let state: AppState
    /// Hover, Klick und Kontextmenü (aus beim Rendern der Vorschaubilder ohne Maus).
    var interactive = true
    /// Fester Zeitpunkt der Animation für gerenderte Vorschauen.
    var frozenTime: Date?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.forcedAccessibility) private var forced

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if let tree = state.tree, let layout = state.layout {
                let geometry = Self.geometry(for: size, rings: layout.options.maxRings)
                let palette = Palette(scheme: state.prefs.paletteScheme, appearance: PaletteAppearance(colorScheme))
                let colors = state.colors(for: layout, palette: palette)
                let fromColors = state.transition.map {
                    state.colors(for: $0.animation.from, palette: palette, tree: $0.fromTree)
                }
                let rescanning = state.rescanningNodes
                let input = SunburstRenderer.Input(
                    tree: tree, layout: layout, colors: colors, fromColors: fromColors, geometry: geometry,
                    palette: palette, hoverArc: state.hoverArc, hoverNode: state.hoverNode,
                    hoverCenter: state.hoverCenter, selected: Set(state.selection.nodes), primarySelected: state.selected,
                    focusIsRoot: state.focus == 0, showLabels: state.prefs.showLabels, centerTitle: centerTitle(tree),
                    sizeMode: state.prefs.sizeMode, rescanning: rescanning)
                // Das Diagramm läuft nur während einer Zoom-/Änderungsanimation
                // jedes Bild; der Fortschrittsring eines Teil-Rescans liegt in
                // einer eigenen kleinen Ebene mit niedriger Bildrate.
                TimelineView(.animation(paused: frozenTime != nil || state.transition == nil)) { timeline in
                    let now = frozenTime ?? timeline.date
                    let t = state.transition.map { ZoomEasing.easeInOut($0.progress(at: now)) }
                    Canvas(opaque: false, rendersAsynchronously: false) { gc, canvasSize in
                        SunburstRenderer.draw(input, transition: state.transition?.animation, progress: t,
                                              in: &gc, size: canvasSize)
                    }
                }
                .overlay {
                    if !rescanning.isEmpty, state.transition == nil {
                        RescanProgressLayer(input: input, frozenTime: frozenTime,
                                            reduceMotion: systemReduceMotion || forced.reduceMotion)
                    }
                }
                .contentShape(Rectangle())
                .modifier(SunburstInteraction(state: state, geometry: geometry, size: size, enabled: interactive))
                .overlay(alignment: .topLeading) {
                    if interactive || frozenTime != nil {
                        SunburstTooltip(state: state, tree: tree, layout: layout, size: size)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("sunburst.accessibility", tree.name(of: state.focus)))
                .accessibilityChildren {
                    SunburstAccessibilityChildren(state: state, tree: tree, layout: layout)
                }
            } else {
                Color.clear
            }
        }
    }

    private func centerTitle(_ tree: ScanTree) -> String {
        if state.focus == ScanTree.rootIndex, state.isVolumeRoot, let v = state.volume { return v.name }
        return tree.name(of: state.focus)
    }

    static func geometry(for size: CGSize, rings: Int) -> SunburstGeometry {
        let outer = max(10, min(size.width, size.height) / 2 - 12)
        return SunburstGeometry(rings: rings, outerRadius: outer)
    }
}

/// Hover, Klick und Kontextmenü auf dem Diagramm.
private struct SunburstInteraction: ViewModifier {
    let state: AppState
    let geometry: SunburstGeometry
    let size: CGSize
    let enabled: Bool

    func hit(_ p: CGPoint) -> SunburstHit {
        guard let layout = state.layout else { return .none }
        return SunburstHitTester(layout: layout, geometry: geometry)
            .hit(dx: p.x - size.width / 2, dy: p.y - size.height / 2)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): state.hoverDiagram(hit(p), at: p)
                    case .ended: state.hoverDiagram(.none, at: nil)
                    }
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                    // Doppelklick über `clickCount`, damit der Einzelklick nicht wartet.
                    state.click(hit(p), clickCount: NSApp.currentEvent?.clickCount ?? 1)
                }
                .contextMenu {
                    if let target = contextTarget { NodeContextMenu(state: state, node: target) }
                }
        } else {
            content
        }
    }

    /// Knoten für das Kontextmenü: das Segment unter der Maus bzw. die Mitte.
    private var contextTarget: Int32? {
        if state.hoverCenter { return state.focus }
        return state.hoverNode
    }
}

/// Fortschrittsring laufender Teil-Rescans als eigene Ebene: Nur sie wird
/// bei unbestimmtem Fortschritt animiert (15 Bilder/s), das Diagramm
/// darunter nicht. Bei „Bewegung reduzieren“ steht der Ring still.
private struct RescanProgressLayer: View {
    let input: SunburstRenderer.Input
    let frozenTime: Date?
    let reduceMotion: Bool

    var body: some View {
        let animates = !reduceMotion && frozenTime == nil && input.rescanning.values.contains { $0 < 0 }
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !animates)) { timeline in
            let now = frozenTime ?? timeline.date
            Canvas(opaque: false, rendersAsynchronously: false) { gc, size in
                SunburstRenderer.drawRescanProgress(input, time: now.timeIntervalSinceReferenceDate,
                                                    animated: !reduceMotion, in: &gc, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Ein unsichtbares Element je Segment im ersten Ring für VoiceOver (SPEC 5).
/// Ordner sind Buttons: Die Standardaktion zoomt hinein (wie ein Klick).
private struct SunburstAccessibilityChildren: View {
    let state: AppState
    let tree: ScanTree
    let layout: SunburstLayout

    var body: some View {
        ForEach(Array(layout.arcs(inRing: 1).enumerated()), id: \.offset) { _, arc in
            let d = describe(arc, tree: tree, layout: layout)
            let label = L("list.row.accessibility", d.title, ByteFormat.string(d.size), ByteFormat.percent(d.share))
            if arc.kind == .node && arc.isDirectory {
                Rectangle()
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { state.navigate(to: arc.nodeIndex) }
                    .accessibilityAction(named: L("accessibility.zoomIn")) { state.navigate(to: arc.nodeIndex) }
            } else if arc.kind == .node {
                // Datei: Standardaktion wählt sie aus (Liste klappt bis dorthin auf).
                Rectangle()
                    .accessibilityLabel(label)
                    .accessibilityAction { state.select(arc.nodeIndex) }
            } else {
                Rectangle().accessibilityLabel(label)
            }
        }
    }
}

/// Tooltip am Mauszeiger: Pfad, Größe, Anteil und Anzahl der Elemente.
private struct SunburstTooltip: View {
    let state: AppState
    let tree: ScanTree
    let layout: SunburstLayout
    let size: CGSize
    /// Breite wächst mit der Textgröße.
    @ScaledMetric(relativeTo: .callout) private var width: CGFloat = 260

    var body: some View {
        if let loc = state.hoverLocation, let content = content {
            let x = min(max(8, loc.x + 16), max(8, size.width - width - 8))
            let y = loc.y + 18 + 90 > size.height ? loc.y - 100 : loc.y + 18
            VStack(alignment: .leading, spacing: 3) {
                Text(content.title).font(.callout.weight(.semibold)).lineLimit(1)
                if let p = content.path {
                    Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(ByteFormat.string(content.size)).font(.subheadline.weight(.medium).monospacedDigit())
                    Text(L("sunburst.shareOf", ByteFormat.percent(content.share), focusName)).font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(content.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    /// Bezugsgröße des Anteils: der Fokus (an der Volume-Wurzel samt
    /// „Nicht zugeordnet“), wie in der Liste.
    private var focusName: String {
        if state.focus == ScanTree.rootIndex, state.isVolumeRoot, let v = state.volume { return v.name }
        return tree.name(of: state.focus)
    }

    private var content: ArcDescription? {
        if state.hoverCenter {
            let n = tree[state.focus]
            let parts = n.parent == nil ? [filesText(n.fileCount)] : [filesText(n.fileCount), L("sunburst.center.hint")]
            return ArcDescription(title: n.name, path: n.path, size: n.size(state.prefs.sizeMode), share: 1,
                                  detail: TextFormat.inline(parts))
        }
        guard let i = state.hoverArc, i < layout.arcs.count else { return nil }
        return describe(layout.arcs[i], tree: tree, layout: layout)
    }
}
