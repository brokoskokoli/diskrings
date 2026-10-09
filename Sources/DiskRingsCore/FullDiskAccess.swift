import Darwin
import Foundation

/// Erkennung des Festplattenvollzugriffs (SPEC 3.1, 7).
public enum FullDiskAccess {
    /// Systemeinstellung „Datenschutz & Sicherheit → Festplattenvollzugriff“.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Status nach einem Lesetest auf geschützte Orte.
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// Keiner der Testorte existiert; der Status lässt sich nicht bestimmen.
        case unknown
    }

    /// Testorte: nur mit Festplattenvollzugriff lesbar.
    public static func probePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/Library/Safari",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Mail",
        ]
    }

    /// Öffnet die Testorte nacheinander nur lesend (ohne Inhalt zu lesen).
    /// Eines lesbar → `granted`; mindestens eines mit `EPERM`/`EACCES` → `denied`.
    public static func status(probing paths: [String] = probePaths()) -> Status {
        var sawDenied = false
        for p in paths {
            let fd = open(p, O_RDONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return .granted
            }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return sawDenied ? .denied : .unknown
    }

    public static var isGranted: Bool { status() == .granted }
}
