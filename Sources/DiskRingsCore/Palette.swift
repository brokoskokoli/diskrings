import Foundation

/// Farbe als reine RGB-Werte (0…1), ohne SwiftUI/AppKit.
public struct RGBColor: Sendable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    /// HSB mit Farbton in Grad (0…360), Sättigung und Helligkeit 0…1.
    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let s = saturation.clamped01, v = brightness.clamped01
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// Farbton (Grad), Sättigung und Helligkeit.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let mx = max(red, green, blue), mn = min(red, green, blue)
        let d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == red { h = 60 * ((green - blue) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == green { h = 60 * ((blue - red) / d + 2) }
            else { h = 60 * ((red - green) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// Relative Leuchtdichte nach WCAG (für die Wahl der Textfarbe).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// Kontrastverhältnis nach WCAG (1…21).
    public func contrast(to other: RGBColor) -> Double {
        let a = luminance + 0.05, b = other.luminance + 0.05
        return max(a, b) / min(a, b)
    }

    /// Lineare Mischung mit `other` (t = 0 → self, t = 1 → other).
    public func mixed(with other: RGBColor, _ t: Double) -> RGBColor {
        let t = t.clamped01
        return RGBColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                        blue: blue + (other.blue - blue) * t, alpha: alpha + (other.alpha - alpha) * t)
    }

    public func withAlpha(_ a: Double) -> RGBColor { RGBColor(red: red, green: green, blue: blue, alpha: a) }

    /// „#RRGGBB“ (ohne Alpha).
    public var hex: String {
        func h(_ v: Double) -> String {
            let s = String(Int((v * 255).rounded()), radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + h(red) + h(green) + h(blue)
    }

    public var description: String { hex }
}

extension Double {
    var clamped01: Double { self.isNaN ? 0 : Swift.min(Swift.max(self, 0), 1) }
}

/// Hell- oder Dunkelmodus.
public enum PaletteAppearance: String, Sendable, CaseIterable {
    case light, dark
}

/// Farbschema des Diagramms (SPEC 3.4 „Farbe“).
public enum PaletteScheme: String, Sendable, CaseIterable {
    /// Ein Farbton je Top-Level-Ast, nach außen heller bzw. weniger gesättigt.
    case branch
    /// Nach Dateityp-Kategorie, mit Legende.
    case fileType
}

/// Dateityp-Kategorien für das alternative Farbschema.
public enum FileTypeCategory: String, Sendable, CaseIterable {
    case video, image, audio, archive, application, code, document, other

    /// Deutsche Bezeichnung für die Legende.
    public var label: String {
        switch self {
        case .video: "Video"
        case .image: "Bilder"
        case .audio: "Audio"
        case .archive: "Archive"
        case .application: "Apps"
        case .code: "Code"
        case .document: "Dokumente"
        case .other: "Sonstiges"
        }
    }

    private static let byExtension: [String: FileTypeCategory] = {
        var m: [String: FileTypeCategory] = [:]
        func add(_ c: FileTypeCategory, _ exts: String) {
            for e in exts.split(separator: " ") { m[String(e)] = c }
        }
        add(.video, "mp4 m4v mov avi mkv wmv flv webm mpg mpeg 3gp mts m2ts vob ts prproj fcpbundle")
        add(.image, "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 cr3 nef arw dng orf rw2 psd svg ico icns photoslibrary exr")
        add(.audio, "mp3 m4a aac wav aif aiff flac ogg opus caf alac wma mid midi logicx band")
        add(.archive, "zip gz tgz bz2 xz 7z rar tar dmg iso pkg sparseimage sparsebundle zst lz4 cpio xip jar war")
        add(.application, "app dylib framework kext appex plugin bundle so exe dll xpc")
        add(.code, "swift c h m mm cpp hpp cc js mjs ts tsx jsx py rb go rs java kt php cs sh zsh json yml yaml toml xml html css scss sql pyc o a class gradle xcodeproj xcworkspace")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md csv odt ods odp epub tex")
        return m
    }()

    /// Kategorie nach Dateiendung (Groß-/Kleinschreibung egal). Ordner ohne
    /// bekannte Paket-Endung sind `.other`.
    public static func classify(name: String) -> FileTypeCategory {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...].lowercased()
        return byExtension[ext] ?? .other
    }
}

/// Farbpalette für das Diagramm, getrennt für Hell- und Dunkelmodus.
///
/// Schema „Ast“: Jeder Arc im ersten Ring bekommt einen Farbton aus einer
/// festen Folge gut unterscheidbarer Töne; seine Nachfahren behalten den Ton
/// (mit kleiner Verschiebung je nach Lage im Ast) und werden nach außen heller
/// und weniger gesättigt. Dateien sind gedämpfter als Ordner, Sammelsegmente
/// grau, „Nicht zugeordnet“ ein dunkleres Neutralgrau.
public struct Palette: Sendable, Equatable {
    public var scheme: PaletteScheme
    public var appearance: PaletteAppearance

    public init(scheme: PaletteScheme = .branch, appearance: PaletteAppearance = .light) {
        self.scheme = scheme
        self.appearance = appearance
    }

    /// Farbtöne (Grad) der Top-Level-Äste in Vergabereihenfolge.
    public static let branchHues: [Double] = [212, 28, 152, 345, 268, 46, 188, 312, 98, 8, 236, 128]

    var isDark: Bool { appearance == .dark }

    // MARK: Flächen und Text

    public var background: RGBColor { isDark ? RGBColor(red: 0.118, green: 0.118, blue: 0.125) : RGBColor(white: 1) }
    /// Trennlinie zwischen Segmenten (Hintergrundfarbe).
    public var separator: RGBColor { background }
    public var centerFill: RGBColor { isDark ? RGBColor(white: 0.20) : RGBColor(white: 0.955) }
    public var centerHoverFill: RGBColor { isDark ? RGBColor(white: 0.26) : RGBColor(white: 0.91) }
    public var primaryText: RGBColor { isDark ? RGBColor(white: 0.94) : RGBColor(white: 0.11) }
    public var secondaryText: RGBColor { isDark ? RGBColor(white: 0.64) : RGBColor(white: 0.42) }
    public var aggregateFill: RGBColor { isDark ? RGBColor(white: 0.32) : RGBColor(white: 0.80) }
    public var remainderFill: RGBColor { isDark ? RGBColor(white: 0.28) : RGBColor(white: 0.88) }
    public var unassignedFill: RGBColor { isDark ? RGBColor(white: 0.40) : RGBColor(white: 0.66) }

    /// Textfarbe mit dem besseren Kontrast auf `fill` (Schwarz oder Weiß; damit
    /// ist das Kontrastverhältnis auf jeder Fläche mindestens 4,58 : 1).
    public func label(on fill: RGBColor) -> RGBColor {
        let dark = RGBColor(white: 0), light = RGBColor(white: 1)
        return fill.contrast(to: dark) >= fill.contrast(to: light) ? dark : light
    }

    /// Hervorgehobene Variante (Hover/Auswahl).
    public func highlighted(_ c: RGBColor) -> RGBColor {
        isDark ? c.mixed(with: RGBColor(white: 1), 0.28) : c.mixed(with: RGBColor(white: 0), 0.10)
    }

    /// Abgeschwächte Variante (andere Segmente, wenn eines hervorgehoben ist).
    public func dimmed(_ c: RGBColor) -> RGBColor { c.mixed(with: background, 0.45) }

    // MARK: Segmentfarben

    /// Farbe eines Ordners bzw. einer Datei im Schema „Ast“.
    /// - Parameters:
    ///   - branchIndex: Position des Asts im ersten Ring (0, 1, 2 …).
    ///   - depth: Ring (1 = innen).
    ///   - position: Lage innerhalb des Asts (0…1), für eine leichte Tonverschiebung.
    public func branchColor(branchIndex: Int, depth: Int, position: Double = 0.5, isDirectory: Bool) -> RGBColor {
        let hues = Self.branchHues
        let baseHue = hues[((branchIndex % hues.count) + hues.count) % hues.count]
        let hue = baseHue + (position.clamped01 - 0.5) * 18
        let step = Double(max(depth, 1) - 1)
        var s: Double, b: Double
        if isDark {
            s = 0.66 - 0.065 * step
            b = 0.80 + 0.02 * step
        } else {
            s = 0.70 - 0.085 * step
            b = 0.80 + 0.03 * step
        }
        if !isDirectory {
            s *= 0.55
            b = isDark ? b - 0.10 : min(b + 0.04, 0.98)
        }
        return RGBColor(hue: hue, saturation: max(s, 0.12), brightness: min(b, 0.98))
    }

    /// Farbe einer Dateityp-Kategorie.
    public func categoryColor(_ c: FileTypeCategory) -> RGBColor {
        let (h, s, b): (Double, Double, Double) = switch c {
        case .video: (350, 0.62, 0.86)
        case .image: (32, 0.70, 0.94)
        case .audio: (282, 0.50, 0.82)
        case .archive: (48, 0.70, 0.88)
        case .application: (212, 0.62, 0.88)
        case .code: (150, 0.55, 0.72)
        case .document: (190, 0.55, 0.78)
        case .other: (220, 0.10, isDark ? 0.62 : 0.74)
        }
        return RGBColor(hue: h, saturation: isDark ? s * 0.9 : s, brightness: isDark ? b * 0.88 : b)
    }

    /// Ordnerfarbe im Schema „Dateityp“: neutral, nach außen heller.
    public func neutralFolderColor(depth: Int) -> RGBColor {
        let step = Double(max(depth, 1) - 1)
        return isDark
            ? RGBColor(hue: 220, saturation: 0.10, brightness: 0.42 + 0.04 * step)
            : RGBColor(hue: 220, saturation: 0.10, brightness: 0.66 + 0.04 * step)
    }

    /// Farben aller Arcs eines Layouts, in derselben Reihenfolge wie `layout.arcs`.
    public func colors(for layout: SunburstLayout, tree: ScanTree) -> [RGBColor] {
        let arcs = layout.arcs
        var out = [RGBColor]()
        out.reserveCapacity(arcs.count)
        // Position der Äste im ersten Ring (für die Tonvergabe) und
        // Kategorien bei Paketen wie .app, die ihren Inhalt mitfärben.
        var branchOrder = [Int32: Int]()
        var categories = [FileTypeCategory?](repeating: nil, count: arcs.count)
        var nextBranch = 0
        for (i, arc) in arcs.enumerated() {
            switch arc.kind {
            case .aggregate:
                out.append(aggregateFill)
            case .remainder:
                out.append(remainderFill)
            case .unassigned:
                out.append(unassignedFill)
            case .node:
                switch scheme {
                case .branch:
                    let bi: Int
                    if let b = branchOrder[arc.branch] { bi = b } else {
                        bi = nextBranch
                        branchOrder[arc.branch] = bi
                        nextBranch += 1
                    }
                    let root = arcs[Int(arc.branch)]
                    let pos = root.span > 0 ? (arc.midAngle - root.startAngle) / root.span : 0.5
                    out.append(branchColor(branchIndex: bi, depth: Int(arc.depth), position: pos,
                                           isDirectory: arc.isDirectory))
                case .fileType:
                    let inherited = arc.parentArc >= 0 ? categories[Int(arc.parentArc)] : nil
                    var cat = inherited
                    if cat == nil {
                        let own = FileTypeCategory.classify(name: tree.name(of: arc.nodeIndex))
                        if !arc.isDirectory || own != .other { cat = own }
                    }
                    // Nur Pakete (z. B. .app, .photoslibrary) vererben ihre Kategorie.
                    if arc.isDirectory, inherited == nil, !tree.node(arc.nodeIndex).flags.contains(.package) {
                        categories[i] = nil
                        out.append(neutralFolderColor(depth: Int(arc.depth)))
                        continue
                    }
                    categories[i] = cat
                    let c = categoryColor(cat ?? .other)
                    out.append(arc.isDirectory ? c : c.mixed(with: background, isDark ? 0.12 : 0.10))
                }
            }
        }
        return out
    }
}
