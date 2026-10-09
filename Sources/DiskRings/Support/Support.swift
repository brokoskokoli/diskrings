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

    /// Zusätzliche Kennzeichen als Text („Paket“, „nicht lesbar“ …).
    var badges: [String] {
        var out: [String] = []
        if isPackage { out.append("Paket") }
        if isUnreadable { out.append("nicht lesbar") }
        if flags.contains(.dataless) { out.append("nur in iCloud") }
        if isSymlink { out.append("Symlink") }
        if flags.contains(.mountPoint) { out.append("anderes Volume") }
        if flags.contains(.hardlinkDuplicate) { out.append("Hardlink") }
        return out
    }
}

/// Text für Anzahl der Elemente („1 Datei“, „312 841 Dateien“).
func filesText(_ n: Int) -> String {
    n == 1 ? "1 Datei" : "\(ByteFormat.count(n)) Dateien"
}

func itemsText(_ n: Int) -> String {
    n == 1 ? "1 kleineres Element" : "\(ByteFormat.count(n)) kleinere Elemente"
}

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
        var detail = n.isDirectory ? filesText(n.fileCount) : (n.badges.first ?? "Datei")
        if n.isDirectory, !n.badges.isEmpty { detail += " · " + n.badges.joined(separator: ", ") }
        return ArcDescription(title: n.name, path: n.path, size: arc.size, share: share, detail: detail)
    case .aggregate:
        return ArcDescription(title: itemsText(Int(arc.itemCount)), path: tree.path(of: arc.nodeIndex),
                              size: arc.size, share: share, detail: "zusammengefasst, jeweils unter der Winkelschwelle")
    case .remainder:
        return ArcDescription(title: "Dateien in diesem Ordner", path: tree.path(of: arc.nodeIndex), size: arc.size,
                              share: share, detail: "noch nicht einzeln erfasst")
    case .unassigned:
        return ArcDescription(title: "Nicht zugeordnet", path: nil, size: arc.size, share: share,
                              detail: "System, lokale Snapshots, bereinigbarer Speicher")
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
