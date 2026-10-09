import Foundation

/// Erkennt, dass ein laufender Scan sich nicht mehr bewegt (SPEC 3.2,
/// Nachbesserung): Öffnet ein Worker z. B. `~/Downloads`, `~/Desktop`, ein
/// Wechsel- oder Netzlaufwerk, kann macOS einen Datenschutz-Dialog (TCC)
/// zeigen und den Aufruf bis zur Antwort blockieren. Ohne Hinweis sähe das
/// aus, als hinge die App.
///
/// Als Bewegung zählt ein neuer Eintrag (Datei oder Ordner) oder ein neuer
/// Herzschlag (`ScanProgress.heartbeat`, ein gelesener Block): In einem
/// Ordner mit 1 Mio. Dateien steigen die Zähler erst nach 5–9 s, die Blöcke
/// kommen aber laufend. Die Engine meldet den Fortschritt auch ohne Änderung
/// alle 250 ms; das zählt nicht. Die Uhrzeit kommt
/// von außen, damit sich die Logik ohne Warten testen lässt.
public struct ScanStallDetector: Sendable, Equatable {
    /// Ab so vielen Sekunden ohne neue Einträge gilt der Scan als stillstehend.
    public static let defaultThreshold: TimeInterval = 3

    public let threshold: TimeInterval
    /// Letzter gesehener Zählerstand (Dateien + Ordner).
    public private(set) var lastCount: Int = 0
    /// Letzter gesehener Herzschlag.
    public private(set) var lastHeartbeat: UInt64 = 0
    /// Zeitpunkt der letzten Bewegung (oder des Scan-Starts).
    public private(set) var lastChange: Date

    public init(start: Date, threshold: TimeInterval = ScanStallDetector.defaultThreshold) {
        self.threshold = threshold
        lastChange = start
    }

    public mutating func observe(_ p: ScanProgress, at date: Date) {
        let count = p.filesScanned + p.directoriesScanned
        if count != lastCount || p.heartbeat != lastHeartbeat {
            lastCount = count
            lastHeartbeat = p.heartbeat
            lastChange = date
        }
    }

    public func isStalled(at date: Date) -> Bool { date.timeIntervalSince(lastChange) > threshold }

    /// Dauer des Stillstands in Sekunden, `nil`, solange keiner vorliegt.
    public func stalledFor(at date: Date) -> TimeInterval? {
        isStalled(at: date) ? date.timeIntervalSince(lastChange) : nil
    }
}

extension FullDiskAccess {
    /// Soll vor dem Scan ein Hinweis-Dialog („Festplattenvollzugriff
    /// einrichten“ / „Trotzdem scannen“) erscheinen? Nur vor einem Scan der
    /// Startvolume-Wurzel (auch über `/System/Volumes/Data`) oder des
    /// Home-Ordners, nur wenn der Zugriff nachweislich fehlt (`denied`) und
    /// der Nutzer den Hinweis nicht schon mit „Trotzdem scannen“ quittiert hat.
    public static func shouldWarnBeforeScan(of path: String, home: String = NSHomeDirectory(), status: Status,
                                            dismissed: Bool) -> Bool {
        guard status == .denied, !dismissed else { return false }
        let p = ProtectedPaths.normalize(path)
        return p == "/" || p == ProtectedPaths.normalize(home)
    }
}
