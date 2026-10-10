import Darwin
import Foundation

/// Laufzeitumgebung der App: Download-Version (nicht sandboxed) oder
/// Mac-App-Store-Variante in der App Sandbox (SPEC 11). Beide entstehen aus
/// demselben Code; erkannt wird die Sandbox zur Laufzeit, ohne Compiler-Flag.
/// Für Tests und Vorschaubilder lässt sich die Umgebung übergeben.
public struct AppEnvironment: Sendable, Equatable {
    /// Läuft die App in der App Sandbox?
    public var isSandboxed: Bool

    public init(isSandboxed: Bool) {
        self.isSandboxed = isSandboxed
    }

    /// Aus den Umgebungsvariablen des Prozesses: macOS setzt
    /// `APP_SANDBOX_CONTAINER_ID` für jede sandboxed App.
    public init(environment: [String: String]) {
        self.init(isSandboxed: environment["APP_SANDBOX_CONTAINER_ID"] != nil)
    }

    /// Umgebung des laufenden Prozesses.
    public static let current = AppEnvironment(environment: ProcessInfo.processInfo.environment)

    /// Echter Home-Ordner des Benutzers. In der Sandbox liefert
    /// `NSHomeDirectory()` den Container (`~/Library/Containers/<id>/Data`);
    /// Schutzliste, „Benutzerordner scannen“ und Hinweise brauchen aber den
    /// echten Ordner, deshalb dort aus der Benutzerdatenbank (`getpwuid`).
    public var homeDirectory: String {
        guard isSandboxed else { return NSHomeDirectory() }
        return Self.accountHomeDirectory() ?? NSHomeDirectory()
    }

    /// Home-Ordner laut Benutzerdatenbank.
    static func accountHomeDirectory() -> String? {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let s = String(cString: dir)
        return s.isEmpty ? nil : s
    }
}
