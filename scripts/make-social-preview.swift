#!/usr/bin/env swift
// Erzeugt das Vorschaubild für GitHub (Settings → Social preview) und für
// Open Graph / Twitter Card der Website: 1280 × 640 px mit Icon, Name,
// Untertitel und Screenshot.
//
//   swift scripts/make-social-preview.swift
//
// Eingaben: docs/images/icon.png, docs/images/hero-dark.png
// Ergebnis: docs/images/social-preview.png
import AppKit

let width: CGFloat = 1280, height: CGFloat = 640
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
func load(_ rel: String) -> NSImage {
    guard let img = NSImage(contentsOf: root.appendingPathComponent(rel)) else {
        FileHandle.standardError.write(Data("fehlt: \(rel)\n".utf8)); exit(1)
    }
    return img
}
let icon = load("docs/images/icon.png")
let shot = load("docs/images/hero-dark.png")

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Hintergrund: dunkler Verlauf wie das Icon.
let bg = NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.09, blue: 0.14, alpha: 1),
                             NSColor(srgbRed: 0.13, green: 0.16, blue: 0.25, alpha: 1)])!
bg.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 35)

// Screenshot rechts, angeschnitten, mit Schatten und runden Ecken.
let shotW: CGFloat = 760
let shotH = shotW * shot.size.height / shot.size.width
let shotRect = NSRect(x: 590, y: (height - shotH) / 2 - 10, width: shotW, height: shotH)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
let clip = NSBezierPath(roundedRect: shotRect, xRadius: 14, yRadius: 14)
NSColor.black.setFill()
clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
clip.addClip()
shot.draw(in: shotRect)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.12).setStroke()
clip.lineWidth = 1.5
clip.stroke()

// Icon, Name, Untertitel links.
icon.draw(in: NSRect(x: 64, y: 388, width: 150, height: 150))
func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint, width w: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    let r = a.boundingRect(with: NSSize(width: w, height: 400), options: [.usesLineFragmentOrigin])
    a.draw(with: NSRect(x: p.x, y: p.y - r.height, width: w, height: r.height), options: [.usesLineFragmentOrigin])
}
text("DiskRings", .systemFont(ofSize: 84, weight: .bold), .white, at: NSPoint(x: 64, y: 372), width: 520)
text("Free, open-source disk space analyzer for macOS with an interactive sunburst chart",
     .systemFont(ofSize: 31, weight: .regular), NSColor.white.withAlphaComponent(0.82),
     at: NSPoint(x: 66, y: 262), width: 500)
text("Snapshots & compare  ·  Trash with undo  ·  macOS 14+",
     .systemFont(ofSize: 20, weight: .medium), NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 1),
     at: NSPoint(x: 66, y: 92), width: 520)

NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("docs/images/social-preview.png")
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: out)
print(out.path)
