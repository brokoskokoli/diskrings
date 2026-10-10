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

    /// Status für die Oberfläche: In der Sandbox (App-Store-Variante) gibt es
    /// keinen Festplattenvollzugriff, der helfen würde; dort zählen nur die
    /// freigegebenen Ordner. Dann immer `unknown`, damit weder Banner noch
    /// Hinweis vor dem Scan noch der Weg in die Systemeinstellung erscheinen.
    public static func status(in environment: AppEnvironment, probing paths: [String]? = nil) -> Status {
        if environment.isSandboxed { return .unknown }
        return status(probing: paths ?? probePaths(home: environment.homeDirectory))
    }
}
