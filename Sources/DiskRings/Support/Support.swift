import AppKit
import DiskRingsCore
import SwiftUI

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
        if n.isDirectory, !n.badges.isEmpty { detail += " · " + n.badges.joined(separator: L("list.separator")) }
        return ArcDescription(title: n.name, path: n.path, size: arc.size, share: share, detail: detail)
    case .aggregate:
        return ArcDescription(title: itemsText(Int(arc.itemCount)), path: tree.path(of: arc.nodeIndex),
                              size: arc.size, share: share, detail: L("arc.aggregate.detail"))
    case .remainder:
        return ArcDescription(title: L("arc.remainder.title"), path: tree.path(of: arc.nodeIndex), size: arc.size,
                              share: share, detail: L("arc.remainder.detail"))
    case .unassigned:
        return ArcDescription(title: L("arc.unassigned.title"), path: nil, size: arc.size, share: share,
                              detail: L("arc.unassigned.detail"))
    }
}

enum Volumes {
    @MainActor static func icon(for path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}

/// Der Property Wrapper `SwiftUI.State` unter anderem Namen. Im SDK von
/// macOS 27 ist `@State` zusätzlich ein Makro (`SwiftUIMacros.StateMacro`),
/// dessen Plugin nur mit Xcode ausgeliefert wird; mit den Command Line Tools
/// schlägt `@State` deshalb fehl (siehe docs/DECISIONS.md).
typealias ViewState<Value> = SwiftUI.State<Value>
