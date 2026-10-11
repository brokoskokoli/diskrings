import Foundation

/// Entscheidet, ob der Updater (Sparkle) in diesem Prozess laufen darf.
///
/// Sparkle gibt es nur in der GitHub-Variante (Package Trait `Updates`); die
/// Mac-App-Store-Variante enthält es gar nicht. Zusätzlich prüft die App zur
/// Laufzeit, damit weder `swift run`, die Bild-Renderer noch ein Bündel ohne
/// öffentlichen Schlüssel einen Updater starten, der nur Fehlermeldungen zeigt
/// (oder unsignierte Updates annehmen müsste).
public enum UpdateConfiguration {
    // Die Info.plist-Schlüssel (`SUFeedURL`, `SUPublicEDKey`) stehen absichtlich
    // nicht hier, sondern in der App unter `#if Updates`: Die Store-Variante soll
    // keine Sparkle-Zeichenketten enthalten (make-app.sh prüft das mit `strings`).

    /// Warum der Updater nicht läuft.
    public enum DisabledReason: Equatable, Sendable {
        /// App Sandbox (App-Store-Variante): Apple erlaubt keine Selbst-Updater.
        case sandboxed
        /// Kein `.app`-Bündel (z. B. `swift run`, Bild-Renderer).
        case notAppBundle
        case missingFeedURL
        /// Feed nicht über HTTPS (oder ohne Host).
        case insecureFeedURL
        /// Kein öffentlicher EdDSA-Schlüssel (Schlüsseldatei im Repo leer).
        case missingPublicKey
        case invalidPublicKey
    }

    public enum Availability: Equatable, Sendable {
        case enabled
        case disabled(DisabledReason)

        public var isEnabled: Bool { self == .enabled }
    }

    /// - Parameters:
    ///   - feedURL: Wert von `SUFeedURL` aus der Info.plist (`nil`, wenn er fehlt).
    ///   - publicKey: Wert von `SUPublicEDKey` aus der Info.plist.
    ///   - bundlePath: Pfad des Haupt-Bündels (`Bundle.main.bundlePath`).
    ///   - environment: Laufzeitumgebung (Sandbox).
    public static func availability(feedURL: Any?, publicKey: Any?, bundlePath: String,
                                    environment: AppEnvironment) -> Availability {
        if environment.isSandboxed { return .disabled(.sandboxed) }
        var path = bundlePath
        while path.hasSuffix("/") { path.removeLast() }
        guard path.lowercased().hasSuffix(".app") else { return .disabled(.notAppBundle) }

        guard let feed = (feedURL as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !feed.isEmpty else { return .disabled(.missingFeedURL) }
        guard let url = URL(string: feed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return .disabled(.insecureFeedURL) }

        guard let raw = publicKey else { return .disabled(.missingPublicKey) }
        guard let key = raw as? String else { return .disabled(.invalidPublicKey) }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .disabled(.missingPublicKey) }
        guard isValidPublicEDKey(key) else { return .disabled(.invalidPublicKey) }
        return .enabled
    }

    /// Öffentlicher Ed25519-Schlüssel, wie ihn Sparkles `generate_keys` ausgibt:
    /// base64 von genau 32 Byte (Leerraum am Rand wird ignoriert).
    public static func isValidPublicEDKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let data = Data(base64Encoded: trimmed) else { return false }
        return data.count == 32
    }
}
