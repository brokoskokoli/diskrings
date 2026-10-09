import Foundation

/// Kennzahlen eines eingehängten Volumes (SPEC 3.1).
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    /// Anzeigename, z. B. „Macintosh HD“.
    public var name: String
    /// Einhängepunkt, z. B. „/“ oder „/Volumes/Backup“.
    public var path: String
    public var uuid: String?
    /// Gesamtgröße (bei APFS die des Containers).
    public var totalCapacity: UInt64
    /// Wirklich frei (`volumeAvailableCapacity`).
    public var availableCapacity: UInt64
    /// Frei für wichtige Daten, inklusive bereinigbarem Speicher
    /// (`volumeAvailableCapacityForImportantUsage`).
    public var availableForImportantUsage: UInt64
    public var isRootFileSystem: Bool
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isReadOnly: Bool

    public var id: String { path }

    public init(
        name: String, path: String, uuid: String? = nil, totalCapacity: UInt64, availableCapacity: UInt64,
        availableForImportantUsage: UInt64, isRootFileSystem: Bool = false, isInternal: Bool = false,
        isRemovable: Bool = false, isReadOnly: Bool = false
    ) {
        self.name = name
        self.path = path
        self.uuid = uuid
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
    }

    /// Belegt = Gesamt − wirklich frei. Bereinigbarer Speicher gilt als belegt.
    public var usedCapacity: UInt64 {
        totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
    }

    /// Bereinigbarer Speicher (Purgeable), soweit vom System gemeldet.
    public var purgeableCapacity: UInt64 {
        availableForImportantUsage > availableCapacity ? availableForImportantUsage - availableCapacity : 0
    }

    /// „Nicht zugeordnet (System, Snapshots, Purgeable)“ = belegt − Scan-Summe
    /// (SPEC 4.1 Punkt 4), bezogen auf dieses Volume.
    public func unassigned(scanTotal: UInt64) -> UInt64 {
        Self.unassigned(volumeUsed: usedCapacity, scanTotal: scanTotal)
    }

    /// Belegt − Scan-Summe, nie negativ. Liegt die Scan-Summe darüber (etwa
    /// durch APFS-Klone, die doppelt gezählt werden), ist das Ergebnis 0.
    public static func unassigned(volumeUsed: UInt64, scanTotal: UInt64) -> UInt64 {
        volumeUsed > scanTotal ? volumeUsed - scanTotal : 0
    }

    static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey,
    ]

    /// Alle sichtbaren eingehängten Volumes.
    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { info(forVolumeURL: $0) }
    }

    /// Das Volume, auf dem `path` liegt.
    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]), let vol = values.volume
        else { return nil }
        return info(forVolumeURL: vol)
    }

    static func info(forVolumeURL url: URL) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        guard let total = v.volumeTotalCapacity else { return nil }
        let available = UInt64(max(v.volumeAvailableCapacity ?? 0, 0))
        let important = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? available
        return VolumeInfo(
            name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
            path: url.path,
            uuid: v.volumeUUIDString,
            totalCapacity: UInt64(max(total, 0)),
            availableCapacity: available,
            availableForImportantUsage: important,
            isRootFileSystem: v.volumeIsRootFileSystem ?? false,
            isInternal: v.volumeIsInternal ?? false,
            isRemovable: v.volumeIsRemovable ?? false,
            isReadOnly: v.volumeIsReadOnly ?? false
        )
    }
}
