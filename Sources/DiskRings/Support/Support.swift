import AppKit
import DiskRingsCore
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    init(_ c: DiskRingsCore.RGBColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

extension PaletteAppearance {
    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
}

extension NodeRef {
    /// SF-Symbol für die Liste und den Tooltip.
    var symbolName: String {
        let f = flags
        if f.contains(.unreadable) { return "lock.fill" }
        if f.contains(.mountPoint) { return "externaldrive" }
        if f.contains(.dataless) { return "icloud" }
        if f.contains(.symlink) { return "arrow.turn.up.right" }
        if f.contains(.package) { return "shippingbox.fill" }
        if isDirectory { return "folder.fill" }
        switch FileTypeCategory.classify(name: name) {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "music.note"
        case .archive: return "doc.zipper"
        case .application: return "app"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text"
        case .other: return "doc"
        }
    }

    /// Zusätzliche Kennzeichen als Text („package“, „unreadable“ …).
    var badges: [String] {
        var out: [String] = []
        if isPackage { out.append(L("badge.package")) }
        if isUnreadable { out.append(L("badge.unreadable")) }
        if flags.contains(.dataless) { out.append(L("badge.icloudOnly")) }
        if isSymlink { out.append(L("badge.symlink")) }
        if flags.contains(.mountPoint) { out.append(L("badge.otherVolume")) }
        if flags.contains(.hardlinkDuplicate) { out.append(L("badge.hardlink")) }
        return out
    }
}

/// Text für Anzahl der Dateien („1 file“, „312,841 files“).
func filesText(_ n: Int) -> String { L10n.files(n) }

/// „1 smaller item“, „12 smaller items“ (Sammelsegment).
func itemsText(_ n: Int) -> String { L("count.smallerItems", n, ByteFormat.count(n)) }

/// Anzeigename und Kennzahlen eines Arcs (für Tooltip, Barrierefreiheit, Liste).
struct ArcDescription {
    var title: String
    var path: String?
    var size: UInt64
    var share: Double
    var detail: String
}

@MainActor
func describe(_ arc: SunburstArc, tree: ScanTree, layout: SunburstLayout) -> ArcDescription {
    let total = max(layout.totalSize, 1)
    let share = Double(arc.size) / Double(total)
    switch arc.kind {
    case .node:
        let n = tree[arc.nodeIndex]
        var detail = n.isDirectory ? filesText(n.fileCount) : (n.badges.first ?? L("kind.file"))
        if n.isDirectory, !n.badges.isEmpty { detail = TextFormat.inline([detail, n.badges.joined(separator: L("list.separator"))]) }
        return ArcDescription(title: n.name, path: n.path, size: arc.size, share: share, detail: detail)
    case .aggregate:
        return ArcDescription(title: itemsText(Int(arc.itemCount)), path: tree.path(of: arc.nodeIndex),
                              size: arc.size, share: share, detail: L("arc.aggregate.detail"))
    case .remainder:
        return ArcDescription(title: L("arc.remainder.title"), path: tree.path(of: arc.nodeIndex), size: arc.size,
                              share: share, detail: L("arc.remainder.detail"))
    case .system, .systemPart, .purgeable, .free:
        let env = AppEnvironment.current
        return ArcDescription(title: layout.volumeSegmentTitle(arc) ?? "", path: nil, size: arc.size, share: share,
                              detail: volumeSegmentDetail(layout, arc, fullDiskAccess: FullDiskAccess.status(in: env),
                                                          sandboxed: env.isSandboxed))
    }
}

/// Erklärung eines Segments der Volume-Wurzel mit dem passenden Hinweis:
/// ohne Festplattenvollzugriff bzw. in der Sandbox (Ordnerfreigaben).
func volumeSegmentDetail(_ layout: SunburstLayout, _ arc: SunburstArc, fullDiskAccess: FullDiskAccess.Status,
                         sandboxed: Bool) -> String {
    if sandboxed, let part = layout.systemPart(of: arc) { return part.detail(accessHint: .sandbox) }
    return layout.volumeSegmentDetail(arc, fullDiskAccessDenied: fullDiskAccess == .denied) ?? ""
}

extension VolumeBreakdown {
    /// Legende des Belegungsbalkens („Ihre Daten 412 GB · Systemdaten 62 GB · …“).
    var legendText: String {
        TextFormat.inline([
            L("legend.yourData", ByteFormat.string(yourData)), L("legend.systemData", ByteFormat.string(systemData)),
            L("start.legend.purgeable", ByteFormat.string(purgeable)), L("start.legend.free", ByteFormat.string(free)),
        ])
    }
}

/// Gestapelter Belegungsbalken: Ihre Daten, Systemdaten, löschbar, frei
/// (Farben wie die Segmente im Diagramm; SPEC 3.1/3.3).
struct VolumeUsageBar: View {
    let breakdown: VolumeBreakdown
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { g in
            let b = breakdown
            let total = Double(max(b.yourData + b.systemData + b.purgeable + b.free, 1))
            let palette = Palette(appearance: PaletteAppearance(colorScheme))
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: g.size.width * Double(b.yourData) / total)
                Rectangle().fill(Color(palette.systemFill)).frame(width: g.size.width * Double(b.systemData) / total)
                Rectangle().fill(Color(palette.purgeableFill)).frame(width: g.size.width * Double(b.purgeable) / total)
                Spacer(minLength: 0)
            }
            .background(Color(palette.freeFill))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .clipShape(Capsule())
        }
        .help(breakdown.legendText)
        .accessibilityElement()
        .accessibilityLabel(breakdown.legendText)
    }
}

/// Legende zum Belegungsbalken mit farbigen Punkten.
struct VolumeUsageLegend: View {
    let breakdown: VolumeBreakdown
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let b = breakdown
        let palette = Palette(appearance: PaletteAppearance(colorScheme))
        HStack(spacing: 12) {
            item(Color.accentColor, L("legend.yourData", ByteFormat.string(b.yourData)))
            if b.systemData > 0 { item(Color(palette.systemFill), L("legend.systemData", ByteFormat.string(b.systemData))) }
            if b.purgeable > 0 {
                item(Color(palette.purgeableFill), L("start.legend.purgeable", ByteFormat.string(b.purgeable)))
            }
            item(Color(palette.freeFill), L("start.legend.free", ByteFormat.string(b.free)))
        }
    }

    private func item(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: 7, height: 7)
            Text(text)
        }
    }
}

enum Volumes {
    /// Icon des Volumes; fehlt der Pfad (gerade ausgeworfen, erfundene Volumes
    /// in den Vorschaubildern), das Icon externer Laufwerke statt eines Dokuments.
    @MainActor static func icon(for path: String) -> NSImage {
        guard FileManager.default.fileExists(atPath: path) else {
            return NSImage(contentsOfFile: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns")
                ?? NSWorkspace.shared.icon(for: .volume)
        }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// Der Property Wrapper `SwiftUI.State` unter anderem Namen. Im SDK von
/// macOS 27 ist `@State` zusätzlich ein Makro (`SwiftUIMacros.StateMacro`),
/// dessen Plugin nur mit Xcode ausgeliefert wird; mit den Command Line Tools
/// schlägt `@State` deshalb fehl (siehe docs/DECISIONS.md).
typealias ViewState<Value> = SwiftUI.State<Value>

/// Erzwungene Bedienungshilfen für die Vorschaubilder: Die Systemwerte
/// (`accessibilityDifferentiateWithoutColor`, `accessibilityReduceMotion`)
/// lassen sich im Environment nicht setzen. Views werten beide aus.
struct ForcedAccessibility: Equatable {
    var differentiateWithoutColor = false
    var reduceMotion = false
}

private struct ForcedAccessibilityKey: EnvironmentKey {
    static let defaultValue = ForcedAccessibility()
}

extension EnvironmentValues {
    var forcedAccessibility: ForcedAccessibility {
        get { self[ForcedAccessibilityKey.self] }
        set { self[ForcedAccessibilityKey.self] = newValue }
    }
}
