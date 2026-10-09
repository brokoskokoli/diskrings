#!/usr/bin/env swift
// Erzeugt das App-Icon von DiskRings programmatisch mit CoreGraphics.
//
//   swift scripts/make-icon.swift
//
// Ergebnis (relativ zum Repo):
//   Resources/DiskRings.icns       – das Icon fürs Bündel (über `iconutil`, eingecheckt)
//   docs/images/icon.png           – 512 px zur Ansicht und für die README
//   build/DiskRings.iconset/       – alle Einzelgrößen (Zwischenstand, nicht eingecheckt)
// Motiv: ein Sunburst aus drei konzentrischen Ringen mit farbigen Segmenten
// auf einem dunklen, abgerundeten Quadrat im Raster der macOS-Icons
// (824 × 824 von 1024, Superellipse). Kleine Größen (≤ 32 px) zeichnen eine
// vereinfachte Variante mit weniger Ringen und breiteren Fugen.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Farben

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    /// Mischt mit Weiß (t > 0) oder Schwarz (t < 0).
    func shade(_ t: CGFloat) -> RGB {
        let target: CGFloat = t > 0 ? 1 : 0
        let k = abs(t)
        return RGB(r: r + (target - r) * k, g: g + (target - g) * k, b: b + (target - b) * k)
    }
}

// MARK: - Motiv (Anteile im Uhrzeigersinn ab 12 Uhr)

/// Ein Ast des Sunbursts: Anteil am Kreis, Grundfarbe und Kinder (Anteile am Ast).
struct Branch {
    var share: CGFloat
    var color: RGB
    var children: [Child]
}

struct Child {
    var share: CGFloat
    /// Anteile der Enkel am Kind; leer = kein dritter Ring an dieser Stelle.
    var grandchildren: [CGFloat]
}

let branches: [Branch] = [
    Branch(share: 0.34, color: RGB(0x3B82F6), children: [ // Blau
        Child(share: 0.55, grandchildren: [0.5, 0.3]),
        Child(share: 0.30, grandchildren: [0.6]),
        Child(share: 0.15, grandchildren: []),
    ]),
    Branch(share: 0.22, color: RGB(0x14B8A6), children: [ // Türkis
        Child(share: 0.6, grandchildren: [0.55, 0.25]),
        Child(share: 0.4, grandchildren: []),
    ]),
    Branch(share: 0.17, color: RGB(0x84CC16), children: [ // Grün
        Child(share: 0.65, grandchildren: [0.7]),
        Child(share: 0.35, grandchildren: []),
    ]),
    Branch(share: 0.15, color: RGB(0xF59E0B), children: [ // Bernstein
        Child(share: 0.7, grandchildren: [0.5]),
        Child(share: 0.3, grandchildren: []),
    ]),
    Branch(share: 0.12, color: RGB(0xF43F5E), children: [ // Rose
        Child(share: 1.0, grandchildren: [0.6]),
    ]),
]

// MARK: - Geometrie

/// Superellipse (n = 5) als Annäherung an die „kontinuierlichen“ Ecken von macOS.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Ringsegment von `start` bis `end` (Anteile 0…1 ab 12 Uhr, im Uhrzeigersinn),
/// mit einer Fuge `gap` (in Punkten) zwischen den Segmenten, gleich breit innen wie außen.
func segmentPath(center c: CGPoint, inner r0: CGFloat, outer r1: CGFloat,
                 start: CGFloat, end: CGFloat, gap: CGFloat) -> CGPath? {
    // CoreGraphics: y nach oben, Winkel gegen den Uhrzeigersinn ab 3 Uhr.
    func angle(_ f: CGFloat) -> CGFloat { .pi / 2 - f * 2 * .pi }
    let a0 = angle(start), a1 = angle(end)
    let dIn = r0 > 0 ? (gap / 2) / r0 : 0
    let dOut = (gap / 2) / r1
    let inStart = a0 - dIn, inEnd = a1 + dIn
    let outStart = a0 - dOut, outEnd = a1 + dOut
    guard outStart > outEnd, r0 == 0 || inStart > inEnd else { return nil }
    let p = CGMutablePath()
    p.addArc(center: c, radius: r1, startAngle: outStart, endAngle: outEnd, clockwise: true)
    if r0 > 0 {
        p.addArc(center: c, radius: r0, startAngle: inEnd, endAngle: inStart, clockwise: false)
    } else {
        p.addLine(to: c)
    }
    p.closeSubpath()
    return p
}

// MARK: - Zeichnen

func drawIcon(size px: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024 // alles im 1024er-Raster beschrieben
    ctx.scaleBy(x: s, y: s)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let small = px <= 32
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: tile)

    // Schlagschatten wie bei den Systemicons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: RGB(0x000000).cg(0.35))
    ctx.addPath(shape)
    ctx.setFillColor(RGB(0x1A2030).cg())
    ctx.fillPath()
    ctx.restoreGState()

    // Hintergrund: dunkles Schieferblau mit sanftem Verlauf von oben nach unten.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [RGB(0x2B3447).cg(), RGB(0x151A26).cg()] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Leichter Glanz oben.
    let glow = CGGradient(colorsSpace: space,
                          colors: [RGB(0xFFFFFF).cg(0.10), RGB(0xFFFFFF).cg(0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    // Sunburst
    let center = CGPoint(x: 512, y: 512)
    let tiny = px <= 16
    let hub: CGFloat = tiny ? 120 : small ? 118 : 104   // Mittelscheibe
    let radii: [CGFloat] = tiny ? [hub + 34, 340] : small ? [hub + 26, 236, 340] : [hub + 16, 220, 292, 350]
    let gap: CGFloat = tiny ? 40 : small ? 26 : 9
    let rings = radii.count - 1
    // Radiale Fuge zwischen den Ringen: der innere Rand jedes Rings rückt nach außen.
    func inner(_ ring: Int) -> CGFloat { ring == 0 ? radii[0] : radii[ring] + gap / 2 }
    func outer(_ ring: Int) -> CGFloat { radii[ring + 1] - (ring == rings - 1 ? 0 : gap / 2) }

    // Mittelscheibe: helle Scheibe mit feinem Verlauf.
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: 2 * hub, height: 2 * hub))
    ctx.clip()
    let hubGrad = CGGradient(colorsSpace: space,
                             colors: [RGB(0xF4F6FA).cg(), RGB(0xC9D0DC).cg()] as CFArray,
                             locations: [0, 1])!
    ctx.drawLinearGradient(hubGrad, start: CGPoint(x: 512, y: 512 + hub), end: CGPoint(x: 512, y: 512 - hub), options: [])
    ctx.restoreGState()

    func fill(_ path: CGPath?, _ color: RGB) {
        guard let path else { return }
        ctx.addPath(path)
        ctx.setFillColor(color.cg())
        ctx.fillPath()
    }

    var start: CGFloat = 0
    for branch in branches {
        let end = start + branch.share
        fill(segmentPath(center: center, inner: inner(0), outer: outer(0), start: start, end: end, gap: gap),
             branch.color)
        if rings >= 2 {
            var cStart = start
            let kids = small ? [Child(share: 1, grandchildren: [])] : branch.children
            for (i, child) in kids.enumerated() {
                let cEnd = cStart + child.share * branch.share
                let tone = branch.color.shade(0.18 + 0.12 * CGFloat(i))
                fill(segmentPath(center: center, inner: inner(1), outer: outer(1), start: cStart, end: cEnd, gap: gap),
                     tone)
                if rings >= 3 {
                    var gStart = cStart
                    for (j, g) in child.grandchildren.enumerated() {
                        let gEnd = gStart + g * (cEnd - cStart)
                        fill(segmentPath(center: center, inner: inner(2), outer: outer(2), start: gStart, end: gEnd, gap: gap),
                             branch.color.shade(0.42 + 0.12 * CGFloat(j)))
                        gStart = gEnd
                    }
                }
                cStart = cEnd
            }
        }
        start = end
    }

    // Feine Kante oben an der Kachel.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(RGB(0xFFFFFF).cg(0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Kann \(url.path) nicht schreiben")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG fehlgeschlagen: \(url.path)") }
}

// MARK: - Ausgabe

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default
let iconset = repo.appendingPathComponent("build/DiskRings.iconset")
let resources = repo.appendingPathComponent("Resources")
let images = repo.appendingPathComponent("docs/images")
try? fm.removeItem(at: iconset)
for dir in [iconset, resources, images] {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(drawIcon(size: px), to: iconset.appendingPathComponent(name))
    }
}
writePNG(drawIcon(size: 512), to: images.appendingPathComponent("icon.png"))

let icns = resources.appendingPathComponent("DiskRings.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil fehlgeschlagen") }
print("==> \(icns.path)")
