import Foundation

/// Titel des Hauptfensters: App-Name mit Versionsnummer, beim Durchsuchen
/// davor der Ordner- bzw. Volume-Name („Library – DiskRings 0.4.0“).
public enum WindowTitle {
    public static let appName = "DiskRings"

    /// `version` ist `CFBundleShortVersionString`; ohne Info.plist (`swift run`)
    /// fehlt sie, dann steht nur der App-Name da.
    public static func make(location: String?, version: String?) -> String {
        let trimmed = version?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = trimmed.isEmpty ? appName : "\(appName) \(trimmed)"
        guard let location, !location.isEmpty else { return app }
        return "\(location) – \(app)"
    }
}
