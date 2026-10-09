/// Eigenschaften eines Knotens im Scan-Baum (16 Bit, siehe SPEC 4.2).
public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Ordner (auch Pakete und nicht lesbare Ordner).
    public static let directory = NodeFlags(rawValue: 1 << 0)
    /// Paket wie `.app` oder `.photoslibrary`; wird normal durchlaufen.
    public static let package = NodeFlags(rawValue: 1 << 1)
    /// Symbolischer Link; wird nicht verfolgt und zählt mit seiner eigenen Größe.
    public static let symlink = NodeFlags(rawValue: 1 << 2)
    /// Ordner konnte nicht gelesen werden (`EACCES`/`EPERM` o. Ä.).
    public static let unreadable = NodeFlags(rawValue: 1 << 3)
    /// Nur in der Cloud vorhanden (`SF_DATALESS`); zählt mit 0 Byte.
    public static let dataless = NodeFlags(rawValue: 1 << 4)
    /// Weiterer Hardlink auf eine bereits gezählte Datei; zählt mit 0 Byte.
    public static let hardlinkDuplicate = NodeFlags(rawValue: 1 << 5)
    /// Einhängepunkt eines anderen Volumes; wird nicht betreten.
    public static let mountPoint = NodeFlags(rawValue: 1 << 6)
    /// Versteckt (Name beginnt mit „.“ oder `UF_HIDDEN`).
    public static let hidden = NodeFlags(rawValue: 1 << 7)
}

/// Kompakter Knoten, 40 Byte. Indizes verweisen in `ScanTree.nodes`,
/// Namen liegen als UTF-8 im gemeinsamen Puffer `ScanTree.names`.
public struct Node: Sendable, Equatable {
    /// Belegt auf Platte (`st_blocks * 512`); bei Ordnern die Summe des Teilbaums.
    public internal(set) var allocatedSize: UInt64
    /// Logische Größe (`st_size`); bei Ordnern die Summe des Teilbaums.
    public internal(set) var logicalSize: UInt64
    /// Index des Elternknotens, -1 bei der Wurzel.
    public internal(set) var parent: Int32
    /// Index des ersten Kindes; die Kinder liegen zusammenhängend dahinter.
    public internal(set) var firstChild: Int32
    public internal(set) var childCount: Int32
    public internal(set) var nameOffset: UInt32
    /// Anzahl der Dateien (alles außer Ordnern) im Teilbaum, bei Dateien 1.
    public internal(set) var fileCount: UInt32
    public internal(set) var nameLength: UInt16
    public internal(set) var flags: NodeFlags

    public var isDirectory: Bool { flags.contains(.directory) }

    public func size(_ mode: SizeMode) -> UInt64 {
        mode == .allocated ? allocatedSize : logicalSize
    }
}

/// Welche Größe angezeigt bzw. verglichen wird.
public enum SizeMode: String, Sendable, CaseIterable {
    /// Belegt auf Platte (Standard).
    case allocated
    /// Logische Dateigröße.
    case logical
}
