import Foundation

/// Snapshot-Einstellungen (SPEC 3.7): automatisch nach jedem vollständigen
/// Scan speichern (Standard an) und höchstens `maxCount` Snapshots pro
/// Scan-Wurzel behalten (Standard 20, die ältesten werden gelöscht).
public struct SnapshotRetention: Sendable, Equatable {
    /// Erlaubter Bereich der Höchstzahl.
    public static let maxCountRange: ClosedRange<Int> = 1 ... 500

    public var autoSave: Bool
    public var maxCount: Int {
        didSet { maxCount = Self.maxCountRange.clamp(maxCount) }
    }

    public init(autoSave: Bool = true, maxCount: Int = SnapshotStore.defaultMaxCount) {
        self.autoSave = autoSave
        self.maxCount = Self.maxCountRange.clamp(maxCount)
    }
}

/// Auswahl der Snapshots für „Vergleichen mit…“ (SPEC 3.9).
public enum SnapshotMatching {
    /// Snapshots mit gleicher Volume-UUID und gleicher Scan-Wurzel, neueste
    /// zuerst. Mit `before` nur Snapshots, die vor diesem Zeitpunkt entstanden
    /// sind; so erscheint der automatisch gespeicherte Snapshot des aktuellen
    /// Scans nicht als Vergleichspartner (der Vergleich ergäbe überall 0).
    public static func candidates(_ infos: [SnapshotInfo], rootPath: String, volumeUUID: String?,
                                  before: Date? = nil) -> [SnapshotInfo] {
        infos.filter { info in
            let m = info.metadata
            guard m.rootPath == rootPath, m.volumeUUID == volumeUUID else { return false }
            if let before, m.date >= before { return false }
            return true
        }
        .sorted { $0.metadata.date != $1.metadata.date ? $0.metadata.date > $1.metadata.date : $0.url.path > $1.url.path }
    }

    /// Vorausgewählt ist der jüngste passende Snapshot.
    public static func defaultSelection(_ candidates: [SnapshotInfo]) -> SnapshotInfo? { candidates.first }
}

/// Namen und Datumsangaben von Snapshots für die Oberfläche.
public enum SnapshotNaming {
    /// Entfernt Leerraum am Rand; ein leerer Name wird zu `nil` („ohne Namen“).
    public static func normalized(_ name: String?) -> String? {
        guard let t = name?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Datum mit Uhrzeit im Stil des Locales (de „02.10.2026, 09:14“,
    /// en „Oct 2, 2026 at 9:14 AM“).
    public static func longDate(_ date: Date, timeZone: TimeZone = .current, locale: Locale = L10n.locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Name des Snapshots, sonst „Snapshot of Oct 2, 2026 at 9:14 AM“.
    public static func title(_ m: SnapshotMetadata, timeZone: TimeZone = .current, locale: Locale = L10n.locale) -> String {
        normalized(m.name) ?? L("snapshot.untitled", longDate(m.date, timeZone: timeZone, locale: locale))
    }
}

extension SnapshotStore {
    /// Speichert einen Snapshot und räumt danach die Snapshots derselben
    /// Scan-Wurzel (und desselben Volumes) auf `retention.maxCount` auf.
    @discardableResult
    public func saveAndPrune(_ tree: ScanTree, metadata: SnapshotMetadata, retention: SnapshotRetention) throws
        -> (saved: SnapshotInfo, pruned: [SnapshotInfo]) {
        var meta = metadata
        meta.name = SnapshotNaming.normalized(meta.name)
        let saved = try save(tree, metadata: meta)
        let pruned = try prune(maxCount: retention.maxCount, rootPath: saved.metadata.rootPath,
                               volumeUUID: saved.metadata.volumeUUID)
        return (saved, pruned)
    }

    /// Automatisches Speichern nach einem vollständigen Scan (SPEC 3.7/3.9).
    /// Gibt `nil` zurück, wenn es abgeschaltet ist.
    public func autoSave(_ result: ScanResult, volume: VolumeInfo? = nil, retention: SnapshotRetention,
                         date: Date = Date()) throws -> (saved: SnapshotInfo, pruned: [SnapshotInfo])? {
        guard retention.autoSave else { return nil }
        return try saveAndPrune(result.tree, metadata: .current(for: result, volume: volume, date: date),
                                retention: retention)
    }
}
