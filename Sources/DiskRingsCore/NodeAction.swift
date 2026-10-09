import Foundation

/// Eingebaute Einträge des Kontextmenüs (SPEC 3.5), für Diagramm und Liste
/// gleich. Reihenfolge, Titel, Symbol und Tastenkürzel stehen hier; ob ein
/// Eintrag für bestimmte Knoten verfügbar ist, entscheidet
/// `NodeAction.availability` (testbar, ohne UI). Die Oberfläche nutzt
/// dieselbe Prüfung für Menü **und** Tastenkürzel.
public enum NodeAction: String, CaseIterable, Sendable, Identifiable {
    case revealInFinder, open, quickLook, zoomIn, copyPath, info, rescan, moveToTrash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .revealInFinder: "Im Finder zeigen"
        case .open: "Öffnen"
        case .quickLook: "Quick Look"
        case .zoomIn: "Hier hineinzoomen"
        case .copyPath: "Pfad kopieren"
        case .info: "Informationen"
        case .rescan: "Diesen Ordner neu scannen"
        case .moveToTrash: "In den Papierkorb legen"
        }
    }

    /// Titel für mehrere Ziele („3 Pfade kopieren“).
    public func title(count: Int) -> String {
        guard count > 1 else { return title }
        switch self {
        case .copyPath: return "\(count) Pfade kopieren"
        case .moveToTrash: return "\(count) Objekte in den Papierkorb legen"
        case .revealInFinder: return "\(count) Objekte im Finder zeigen"
        case .open: return "\(count) Objekte öffnen"
        default: return title
        }
    }

    /// SF-Symbol.
    public var symbolName: String {
        switch self {
        case .revealInFinder: "folder"
        case .open: "arrow.up.forward.app"
        case .quickLook: "eye"
        case .zoomIn: "plus.magnifyingglass"
        case .copyPath: "doc.on.doc"
        case .info: "info.circle"
        case .rescan: "arrow.clockwise"
        case .moveToTrash: "trash"
        }
    }

    public var shortcut: ActionShortcut? {
        switch self {
        case .revealInFinder: ActionShortcut(.character("r"), [.command])
        case .quickLook: ActionShortcut(.space, [])
        case .copyPath: ActionShortcut(.character("c"), [.option, .command])
        case .info: ActionShortcut(.character("i"), [.command])
        case .rescan: ActionShortcut(.character("r"), [.shift, .command])
        case .moveToTrash: ActionShortcut(.delete, [.command])
        case .open, .zoomIn: nil
        }
    }

    /// Trennlinie vor diesem Eintrag.
    public var startsGroup: Bool { self == .zoomIn || self == .copyPath || self == .rescan || self == .moveToTrash }

    /// Wirkt auf mehrere Knoten gleichzeitig.
    public var allowsMultipleTargets: Bool {
        switch self {
        case .revealInFinder, .open, .quickLook, .copyPath, .moveToTrash: true
        case .zoomIn, .info, .rescan: false
        }
    }
}

/// Tastenkürzel ohne SwiftUI-Abhängigkeit.
public struct ActionShortcut: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        case character(Character)
        case space
        case delete
    }

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Anzeige wie im Menü („⌥⌘C“, „⌘⌫“, „Leertaste“).
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .character(let c): s += c.uppercased()
        case .space: s += "Leertaste"
        case .delete: s += "⌫"
        }
        return s
    }
}

/// Ob ein Eintrag verfügbar ist, und wenn nicht, warum (für den Tooltip).
public struct ActionAvailability: Sendable, Equatable {
    public var isEnabled: Bool
    public var reason: String?

    public static let enabled = ActionAvailability(isEnabled: true, reason: nil)
    public static func disabled(_ reason: String) -> ActionAvailability {
        ActionAvailability(isEnabled: false, reason: reason)
    }
}

/// Zustand, den die Verfügbarkeitsregeln brauchen.
public struct ActionContext: Sendable {
    public var tree: ScanTree
    public var focus: Int32
    public var protection: ProtectedPaths
    public var sizeMode: SizeMode
    /// Ein vollständiger Scan läuft (der Baum ist ein vorläufiger Snapshot).
    public var isFullScanRunning: Bool
    /// Pfade, die gerade neu eingelesen werden.
    public var rescanningPaths: [String]
    /// Ordner, die beim Scan als Einhängepunkt nicht betreten wurden, werden
    /// nur mit dieser Option neu eingelesen.
    public var crossMountPoints: Bool

    public init(tree: ScanTree, focus: Int32 = ScanTree.rootIndex, protection: ProtectedPaths,
                sizeMode: SizeMode = .allocated, isFullScanRunning: Bool = false, rescanningPaths: [String] = [],
                crossMountPoints: Bool = false) {
        self.tree = tree
        self.focus = focus
        self.protection = protection
        self.sizeMode = sizeMode
        self.isFullScanRunning = isFullScanRunning
        self.rescanningPaths = rescanningPaths
        self.crossMountPoints = crossMountPoints
    }
}

extension NodeAction {
    /// Ist der Eintrag für diese Knoten verfügbar? Gilt gleichermaßen für
    /// Kontextmenü, Hauptmenü und Tastenkürzel (SPEC 9: „Auf geschützte
    /// Pfade ist kein Löschen möglich, auch nicht per Tastenkürzel“).
    public func availability(targets: [Int32], context c: ActionContext) -> ActionAvailability {
        let tree = c.tree
        guard !targets.isEmpty else { return .disabled("Nichts ausgewählt") }
        for t in targets where t < 0 || Int(t) >= tree.count || tree.nodes[Int(t)].flags.contains(.dead) {
            return .disabled("Element ist nicht mehr im Baum")
        }
        if targets.count > 1, !allowsMultipleTargets { return .disabled("Nur für ein einzelnes Element") }
        let first = targets[0]
        let node = tree.node(first)
        switch self {
        case .revealInFinder, .open, .quickLook, .copyPath, .info:
            return .enabled
        case .zoomIn:
            if !node.isDirectory { return .disabled("Nur für Ordner") }
            if first == c.focus { return .disabled("Ist bereits die Mitte") }
            if node.size(c.sizeMode) == 0 { return .disabled("Ordner ist leer") }
            return .enabled
        case .rescan:
            if !node.isDirectory { return .disabled("Nur für Ordner") }
            if c.isFullScanRunning { return .disabled("Während eines vollständigen Scans nicht möglich") }
            if node.flags.contains(.mountPoint), !c.crossMountPoints {
                return .disabled("Anderes Volume (wird beim Scan nicht betreten)")
            }
            let path = tree.path(of: first)
            if let running = c.rescanningPaths.first(where: { RescanQueue.covers($0, path) }) {
                return .disabled(running == path ? "Wird gerade neu gescannt"
                                 : "Wird gerade mit „\((running as NSString).lastPathComponent)“ neu gescannt")
            }
            return .enabled
        case .moveToTrash:
            if c.isFullScanRunning { return .disabled("Während des Scans nicht möglich") }
            switch TrashPlan.make(targets: targets, in: tree, protection: c.protection, sizeMode: c.sizeMode) {
            case .success: return .enabled
            case .failure(let e): return .disabled(e.message)
            }
        }
    }
}
