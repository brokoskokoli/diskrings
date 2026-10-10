import Foundation

/// Aufteilung der Volume-Belegung beim Scan einer Volume-Wurzel (SPEC 4.1 Punkt 4):
/// eigene Daten (Scan-Summe), Systemdaten (andere Volumes im Container und nicht
/// lesbarer Rest), löschbarer Speicher und wirklich freier Speicher.
///
/// Systemdaten und löschbar ergeben zusammen genau das frühere „Nicht zugeordnet“
/// (belegt − Scan-Summe, nie negativ). Reicht dieser Rest nicht für alle
/// Messwerte, werden sie in dieser Reihenfolge zugeteilt und geklemmt: andere
/// Volumes (größte zuerst), dann löschbar; was übrig bleibt, ist „Nicht lesbare
/// Systemdaten“. Rein rechnerisch, ohne Dateisystemzugriff.
public struct VolumeBreakdown: Sendable, Hashable {
    /// Ein Teil der Systemdaten (zweiter Ring im Diagramm).
    public struct SystemPart: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// Ein anderes APFS-Volume im selben Container.
            case volume(ContainerVolume)
            /// Belegung, die weder im Scan noch in einem anderen Volume auftaucht.
            case unreadable
        }

        public var kind: Kind
        public var size: UInt64

        public init(kind: Kind, size: UInt64) {
            self.kind = kind
            self.size = size
        }

        public var title: String {
            switch kind {
            case .volume(let v): v.displayName
            case .unreadable: L("arc.unreadableSystem.title")
            }
        }

        /// Zusatz zu den nicht lesbaren Systemdaten: ohne Festplattenvollzugriff
        /// bzw. in der Sandbox (App-Store-Variante) stecken dort auch Ordner,
        /// die DiskRings nicht lesen durfte.
        public enum AccessHint: Sendable {
            case none, fullDiskAccess, sandbox
        }

        /// Erklärung für Tooltip und Liste.
        public func detail(fullDiskAccessDenied: Bool = false) -> String {
            detail(accessHint: fullDiskAccessDenied ? .fullDiskAccess : .none)
        }

        public func detail(accessHint: AccessHint) -> String {
            switch kind {
            case .volume: return L("arc.volume.detail")
            case .unreadable:
                let base = L("format.sentences", L("arc.unreadableSystem.detail"), L("arc.snapshots.note"))
                switch accessHint {
                case .none: return base
                case .fullDiskAccess: return L("format.sentences", base, L("arc.unreadableSystem.fdaHint"))
                case .sandbox: return L("format.sentences", base, L("arc.unreadableSystem.sandboxHint"))
                }
            }
        }
    }

    public let total: UInt64
    /// Belegt = Gesamt − wirklich frei (bereinigbarer Speicher gilt als belegt).
    public let used: UInt64
    /// Scan-Summe, wie übergeben.
    public let scanned: UInt64
    /// Systemdaten, absteigend nach Größe, ohne leere Teile.
    public let systemParts: [SystemPart]
    /// Davon andere Volumes (geklemmt).
    public let otherVolumes: UInt64
    /// Davon nicht lesbar.
    public let unreadable: UInt64
    /// Löschbar (geklemmt auf den Rest nach den anderen Volumes).
    public let purgeable: UInt64
    /// Wirklich frei (`volumeAvailableCapacity`).
    public let free: UInt64

    public init(total: UInt64, available: UInt64, availableForImportantUsage: UInt64, scanned: UInt64,
                otherVolumes: [ContainerVolume]) {
        self.total = total
        self.free = available
        let used = total > available ? total - available : 0
        self.used = used
        self.scanned = scanned
        var rest = VolumeInfo.unassigned(volumeUsed: used, scanTotal: scanned)

        var parts: [SystemPart] = []
        var others: UInt64 = 0
        let sorted = otherVolumes.filter { $0.used > 0 }.sorted {
            $0.used != $1.used ? $0.used > $1.used : $0.name < $1.name
        }
        for v in sorted where rest > 0 {
            let s = min(v.used, rest)
            rest -= s
            others += s
            parts.append(SystemPart(kind: .volume(v), size: s))
        }
        let reportedPurgeable = availableForImportantUsage > available ? availableForImportantUsage - available : 0
        let purgeable = min(reportedPurgeable, rest)
        rest -= purgeable
        if rest > 0 { parts.append(SystemPart(kind: .unreadable, size: rest)) }
        parts.sort { $0.size > $1.size }

        self.otherVolumes = others
        self.purgeable = purgeable
        self.unreadable = rest
        self.systemParts = parts
    }

    public init(volume v: VolumeInfo, scanned: UInt64, otherVolumes: [ContainerVolume]) {
        self.init(total: v.totalCapacity, available: v.availableCapacity,
                  availableForImportantUsage: v.availableForImportantUsage, scanned: scanned,
                  otherVolumes: otherVolumes)
    }

    /// Aufteilung ohne Scan (Startbildschirm): Alles, was weder andere Volumes
    /// noch löschbar ist, gilt als eigene Daten.
    public static func estimate(volume v: VolumeInfo, otherVolumes: [ContainerVolume]) -> VolumeBreakdown {
        var rest = v.usedCapacity
        for o in otherVolumes { rest -= min(o.used, rest) }
        rest -= min(v.purgeableCapacity, rest)
        return VolumeBreakdown(volume: v, scanned: rest, otherVolumes: otherVolumes)
    }

    /// Systemdaten = andere Volumes + nicht lesbar.
    public var systemData: UInt64 { otherVolumes + unreadable }
    /// Das frühere „Nicht zugeordnet“ = Systemdaten + löschbar = belegt − Scan-Summe.
    public var unassigned: UInt64 { systemData + purgeable }
    /// Eigene Daten im Balken: belegt ohne Systemdaten und löschbar.
    public var yourData: UInt64 { used - unassigned }

    /// Text unter dem Volume-Namen in der Mitte des Diagramms, wenn der freie
    /// Speicher im Ring gezeigt wird („312 GB belegt von 494 GB“).
    public var centerText: String {
        L("center.usedOfTotal", ByteFormat.string(used), ByteFormat.string(total))
    }

    /// Zusätzliche Segmente im ersten Ring des Diagramms.
    public func rootSegments(showFree: Bool) -> RootSegments {
        RootSegments(systemParts: systemParts, purgeable: purgeable, free: showFree ? free : 0)
    }
}

/// Segmente der Volume-Wurzel im Diagramm neben den Ordnern: Systemdaten (mit
/// Teilen im zweiten Ring), löschbar und frei.
public struct RootSegments: Sendable, Hashable {
    public var systemParts: [VolumeBreakdown.SystemPart]
    public var purgeable: UInt64
    public var free: UInt64

    public init(systemParts: [VolumeBreakdown.SystemPart] = [], purgeable: UInt64 = 0, free: UInt64 = 0) {
        self.systemParts = systemParts.filter { $0.size > 0 }
        self.purgeable = purgeable
        self.free = free
    }

    public static let none = RootSegments()

    /// Summe der Systemdaten (sättigend).
    public var system: UInt64 {
        systemParts.reduce(UInt64(0)) { a, p in a.addingReportingOverflow(p.size).overflow ? .max : a + p.size }
    }

    /// Summe aller Segmente (sättigend).
    public var total: UInt64 {
        let (a, o1) = system.addingReportingOverflow(purgeable)
        let (b, o2) = a.addingReportingOverflow(free)
        return o1 || o2 ? .max : b
    }

    public var isEmpty: Bool { total == 0 }
}
