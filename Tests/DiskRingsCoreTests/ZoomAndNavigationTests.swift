@testable import DiskRingsCore
import Foundation
import Testing

@Suite("ZoomTransition")
struct ZoomTransitionTests {
    @Test("Transform: Komposition und Umkehrung")
    func transforms() {
        let e = ZoomTransform.expanding(start: 1, end: 2, depth: 2)
        let c = ZoomTransform.contracting(start: 1, end: 2, depth: 2)
        let id = e.composed(after: c)
        #expect(abs(id.angleScale - 1) < 1e-12 && abs(id.angleOffset) < 1e-12 && id.depthShift == 0)
        #expect(abs(e.angle(1)) < 1e-12)
        #expect(abs(e.angle(2) - twoPi) < 1e-12)
        let half = ZoomTransform.interpolate(c, .identity, 0.5)
        #expect(abs(half.angle(0) - 0.5) < 1e-12)
        #expect(abs(half.angle(twoPi) - (2 + twoPi) / 2) < 1e-12)
        #expect(half.depthShift == 1)
        #expect(ZoomTransform.interpolate(c, .identity, 1) == .identity)
        #expect(ZoomTransform.interpolate(c, .identity, 0) == c)
        #expect(ZoomTransform.interpolate(c, .identity, 7) == .identity) // geklemmt
    }

    @Test("Hineinzoomen: Start deckt sich mit dem alten Bild, Ende mit dem neuen")
    func zoomIn() {
        let t = sampleTree()
        let old = SunburstLayout(tree: t)
        let a = idx(t, "a")
        let new = SunburstLayout(tree: t, focus: a)
        let z = ZoomTransition(from: old, to: new, tree: t)
        #expect(z.kind == .zoomIn)
        // t = 0: Die neuen Arcs liegen genau auf den Arcs derselben Knoten im alten Layout.
        let start = z.frame(at: 0, rings: 6)
        for d in start where d.isFromTarget {
            let arc = new.arcs[d.arcIndex]
            guard arc.kind == .node, let oi = old.arcIndex(ofNode: arc.nodeIndex) else { continue }
            let o = old.arcs[oi]
            #expect(abs(d.startAngle - o.startAngle) < 1e-9)
            #expect(abs(d.endAngle - o.endAngle) < 1e-9)
            #expect(abs(d.outerBoundary - Double(o.depth)) < 1e-9)
        }
        // Die alten Arcs sind bei t = 0 unverändert und voll sichtbar.
        let oldAtStart = start.filter { !$0.isFromTarget }
        #expect(oldAtStart.count == old.arcs.count)
        #expect(oldAtStart.allSatisfy { $0.opacity == 1 })
        // t = 1: nur noch das neue Layout, unverändert.
        let end = z.frame(at: 1, rings: 6)
        #expect(end.allSatisfy { $0.isFromTarget })
        #expect(end.count == new.arcs.count)
        for d in end {
            let arc = new.arcs[d.arcIndex]
            #expect(abs(d.startAngle - arc.startAngle) < 1e-9 && abs(d.endAngle - arc.endAngle) < 1e-9)
            #expect(d.outerBoundary == Double(arc.depth))
        }
        // Zwischendurch: Winkel bleiben in [0, 2π], Tiefen im Diagramm.
        for step in 1 ..< 10 {
            for d in z.frame(at: Double(step) / 10, rings: 6) {
                #expect(d.startAngle >= 0 && d.endAngle <= twoPi + 1e-9 && d.startAngle < d.endAngle)
                #expect(d.innerBoundary >= 0 && d.outerBoundary <= 6 && d.innerBoundary < d.outerBoundary)
                #expect(d.opacity >= 0 && d.opacity <= 1)
            }
        }
    }

    @Test("Herauszoomen: umgekehrte Abbildung")
    func zoomOut() {
        let t = sampleTree()
        let a1 = idx(t, "a/a1")
        let old = SunburstLayout(tree: t, focus: a1)
        let new = SunburstLayout(tree: t)
        let z = ZoomTransition(from: old, to: new, tree: t)
        #expect(z.kind == .zoomOut)
        // t = 0: x und y (Kinder von a1) liegen wie im alten Bild.
        let start = z.frame(at: 0, rings: 6).filter(\.isFromTarget)
        for d in start {
            let arc = new.arcs[d.arcIndex]
            guard arc.kind == .node, let oi = old.arcIndex(ofNode: arc.nodeIndex) else { continue }
            #expect(abs(d.startAngle - old.arcs[oi].startAngle) < 1e-9)
            #expect(abs(d.endAngle - old.arcs[oi].endAngle) < 1e-9)
        }
        // a1 selbst ist bei t = 0 die Mitte und daher unsichtbar.
        let a1Arc = new.arcIndex(ofNode: a1)!
        #expect(!start.contains { $0.arcIndex == a1Arc })
        #expect(z.frame(at: 1, rings: 6).count == new.arcs.count)
    }

    @Test("Ohne Vorfahrenbeziehung wird überblendet")
    func crossfade() {
        let t = sampleTree()
        let l1 = SunburstLayout(tree: t, focus: idx(t, "a"))
        let l2 = SunburstLayout(tree: t, focus: idx(t, "c"))
        let z = ZoomTransition(from: l1, to: l2, tree: t)
        #expect(z.kind == .crossfade)
        let mid = z.frame(at: 0.5, rings: 6)
        #expect(mid.contains { $0.isFromTarget && abs($0.opacity - 0.5) < 1e-9 })
        #expect(mid.contains { !$0.isFromTarget && abs($0.opacity - 0.5) < 1e-9 })
        #expect(z.frame(at: 0, rings: 6).allSatisfy { !$0.isFromTarget })
        // Gleicher Fokus: ebenfalls Überblendung (z. B. neuer Snapshot).
        #expect(ZoomTransition(from: l1, to: l1, tree: t).kind == .crossfade)
    }

    @Test("Easing")
    func easing() {
        #expect(ZoomEasing.easeInOut(0) == 0)
        #expect(ZoomEasing.easeInOut(1) == 1)
        #expect(abs(ZoomEasing.easeInOut(0.5) - 0.5) < 1e-12)
        #expect(ZoomEasing.easeInOut(0.25) < 0.25)
        #expect(ZoomEasing.easeInOut(-1) == 0)
    }
}

@Suite("FocusHistory und Breadcrumb")
struct FocusHistoryTests {
    @Test("Zurück, Vor, neuer Fokus leert Vor")
    func backForward() {
        var h = FocusHistory()
        #expect(!h.canGoBack && !h.canGoForward)
        do { let ok = h.goBack(); #expect(!ok) }
        h.navigate(to: 5)
        h.navigate(to: 9)
        h.navigate(to: 9) // gleicher Knoten: nichts
        #expect(h.current == 9)
        #expect(h.backStack == [0, 5])
        do { let ok = h.goBack(); #expect(ok) }
        #expect(h.current == 5)
        #expect(h.canGoForward)
        do { let ok = h.goForward(); #expect(ok) }
        #expect(h.current == 9)
        do { let ok = h.goForward(); #expect(!ok) }
        h.goBack()
        h.navigate(to: 3)
        #expect(!h.canGoForward)
        #expect(h.backStack == [0, 5])
    }

    @Test("Eine Ebene nach oben")
    func up() {
        let t = sampleTree()
        var h = FocusHistory(root: idx(t, "a/a1"))
        do { let ok = h.goUp(in: t); #expect(ok) }
        #expect(h.current == idx(t, "a"))
        h.goUp(in: t)
        #expect(h.current == 0)
        do { let ok = h.goUp(in: t); #expect(!ok) }
        #expect(h.backStack == [idx(t, "a/a1"), idx(t, "a")])
    }

    @Test("Historie ist begrenzt")
    func limit() {
        var h = FocusHistory()
        for i in 1 ... 500 { h.navigate(to: Int32(i)) }
        #expect(h.backStack.count == FocusHistory.limit)
        #expect(h.current == 500)
    }

    @Test("Breadcrumb-Pfad und Vorfahren")
    func breadcrumb() {
        let t = sampleTree()
        let x = idx(t, "a/a1/x")
        #expect(Breadcrumb.path(in: t, to: x).map { t.name(of: $0) } == ["r", "a", "a1", "x"])
        #expect(Breadcrumb.path(in: t, to: 0) == [0])
        #expect(Breadcrumb.isAncestor(idx(t, "a"), of: x, in: t))
        #expect(Breadcrumb.isAncestor(x, of: x, in: t))
        #expect(!Breadcrumb.isAncestor(idx(t, "c"), of: x, in: t))
    }

    @Test("Übertragen auf einen neuen Baum über Pfade")
    func remap() {
        let old = sampleTree()
        var h = FocusHistory()
        h.navigate(to: idx(old, "c"))
        h.navigate(to: idx(old, "a"))
        h.navigate(to: idx(old, "a/a1"))
        h.goBack()
        // Neuer Baum: c fehlt, a1 ist gewachsen (andere Indizes).
        var b = ScanTreeBuilder(rootName: "r")
        let a = b.directory("a")
        let a1 = b.directory("a1", in: a)
        b.file("neu", size: 5000, in: a1)
        b.file("b", size: 300)
        let new = b.build(rootPath: "/r")
        let m = h.remapped(from: old, to: new)
        #expect(m.current == idx(new, "a"))
        #expect(m.backStack == [0])
        #expect(m.forwardStack == [idx(new, "a/a1")])
        // Fokus verschwunden: nächster vorhandener Vorfahr.
        var h2 = FocusHistory()
        h2.navigate(to: idx(old, "a/a1/x"))
        let m2 = h2.remapped(from: old, to: new)
        #expect(m2.current == idx(new, "a/a1"))
        var h3 = FocusHistory()
        h3.navigate(to: idx(old, "c"))
        #expect(h3.remapped(from: old, to: new).current == 0)
        #expect(h3.remapped(from: old, to: new).backStack.isEmpty)
    }
}

@Suite("Sunburst-Performance", .serialized)
struct SunburstPerformanceTests {
    static let tree = DemoTree.large(nodeCount: 2_000_000)

    func measure(_ iterations: Int, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0 ..< iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return best
    }

    @Test("Layout für 2 Mio. Knoten unter 50 ms, Hit-Test unter 1 ms")
    func twoMillion() {
        let t = Self.tree
        #expect(t.count == 2_000_000)
        var layout: SunburstLayout!
        let layoutMs = measure(5) { layout = SunburstLayout(tree: t, options: SunburstOptions(maxRings: 10)) }
        let logicalMs = measure(3) { _ = SunburstLayout(tree: t, options: SunburstOptions(maxRings: 10, sizeMode: .logical)) }
        let g = SunburstGeometry(rings: 10, outerRadius: 400)
        let h = SunburstHitTester(layout: layout, geometry: g)
        var rng = SplitMix64(seed: 1)
        var hits = 0
        let n = 10_000
        let hitTotalMs = measure(3) {
            for _ in 0 ..< n {
                let x = rng.nextUnit() * 800 - 400, y = rng.nextUnit() * 800 - 400
                if case .arc = h.hit(dx: x, dy: y) { hits += 1 }
            }
        }
        // Ungünstigster Fall: keine Winkelschwelle, alle Kinder einzeln bis zur Arc-Obergrenze.
        var dense: SunburstLayout!
        let denseMs = measure(3) { dense = SunburstLayout(tree: t, options: SunburstOptions(maxRings: 10, minAngleDegrees: 0)) }
        let colorsMs = measure(3) { _ = Palette().colors(for: layout, tree: t) }
        print("Sunburst-Performance (2 Mio. Knoten): Layout \(layoutMs) ms (logisch \(logicalMs) ms), \(layout.arcs.count) Arcs in \(layout.ringCount) Ringen, ohne Schwelle \(denseMs) ms für \(dense.arcs.count) Arcs, Hit-Test \(hitTotalMs / Double(n) * 1000) µs, Farben \(colorsMs) ms")
        #expect(layout.arcs.count > 300)
        #expect(dense.arcs.count > 5000 && dense.arcs.count <= SunburstOptions.defaultMaxArcs)
        #expect(denseMs < 50)
        #expect(hits > 0)
        #expect(layoutMs < 50)
        #expect(logicalMs < 50)
        #expect(hitTotalMs / Double(n) < 1)
    }
}
