import Foundation

/// Lokalisierung der Oberfläche (App und Core) ohne Xcode.
///
/// Die Texte stehen in `Resources/<sprache>.lproj/Localizable.strings` (und
/// `.stringsdict` für Pluralformen) dieses Targets; Schlüssel sind stabile IDs
/// wie `"menu.chooseFolder"`, Quelle und Rückfall ist Englisch (siehe
/// dev/DECISIONS.md, „Lokalisierung“).
///
/// **Bundle:** In der gebauten App kopiert `scripts/make-app.sh` die
/// `.lproj`-Ordner nach `Contents/Resources`; dann gilt das Haupt-Bundle (so
/// kennt macOS die Sprachen und bietet sie pro App an). Bei `swift run`, in
/// den Tests und in der CLI liegt das Ressourcen-Bündel von SwiftPM neben dem
/// Programm (`Bundle.module`).
///
/// **Sprache:** in dieser Reihenfolge
/// 1. `L10n.$override` (Task-Local, für Tests mit fester Sprache),
/// 2. `L10n.setProcessLanguage(_:)` (z. B. `--render-snapshots … --language fr`),
/// 3. automatisch: die bevorzugte Sprache des Nutzers (`AppleLanguages`, auch
///    die Einstellung pro App in den Systemeinstellungen), ohne Treffer Englisch.
public enum L10n {
    /// Entwicklungssprache, Quelle aller Texte und Rückfall.
    public static let developmentLanguage = "en"

    /// Alle mitgelieferten Sprachen (Namen der `.lproj`-Ordner).
    public static let supportedLanguages = [
        "en", "de", "fr", "es", "it", "pt-BR", "nl", "pl", "ru", "ja", "zh-Hans", "ko", "tr", "sv",
    ]

    /// Name jeder Sprache in ihrer eigenen Schreibweise (für die Sprachwahl).
    public static func nativeName(of code: String) -> String {
        switch code {
        case "en": "English"
        case "de": "Deutsch"
        case "fr": "Français"
        case "es": "Español"
        case "it": "Italiano"
        case "pt-BR": "Português (Brasil)"
        case "nl": "Nederlands"
        case "pl": "Polski"
        case "ru": "Русский"
        case "ja": "日本語"
        case "zh-Hans": "简体中文"
        case "ko": "한국어"
        case "tr": "Türkçe"
        case "sv": "Svenska"
        default: Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        }
    }

    /// Feste Sprache für den aktuellen Task (Tests). `nil` = keine Vorgabe.
    @TaskLocal public static var override: String?

    private static let processLanguageLock = NSLock()
    nonisolated(unsafe) private static var processLanguageStorage: String?

    /// Sprache für den ganzen Prozess festlegen (`nil` = automatisch).
    /// Unbekannte Codes werden auf die nächste unterstützte Sprache abgebildet.
    public static func setProcessLanguage(_ code: String?) {
        processLanguageLock.withLock { processLanguageStorage = code.map(resolve) }
    }

    private static var processLanguage: String? {
        processLanguageLock.withLock { processLanguageStorage }
    }

    /// Bevorzugte Sprache des Nutzers, die DiskRings unterstützt (einmal beim
    /// Start bestimmt; ein Wechsel braucht einen Neustart).
    public static let automaticLanguage: String = {
        Bundle.preferredLocalizations(from: supportedLanguages).first.map(resolve) ?? developmentLanguage
    }()

    /// Systemweit bevorzugte Sprache (ohne die Einstellung der App selbst),
    /// die DiskRings unterstützt; gilt nach einem Neustart mit „Automatisch“.
    public static var systemLanguage: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            as? [String] ?? Locale.preferredLanguages
        return preferredSupported(global)
    }

    /// Erste Sprache aus `preferences`, die DiskRings unterstützt; sonst Englisch.
    public static func preferredSupported(_ preferences: [String]) -> String {
        for p in preferences {
            let r = resolve(p)
            if r != developmentLanguage || p.hasPrefix("en") { return r }
        }
        return developmentLanguage
    }

    /// Bildet einen Sprachcode („fr-CA“, „zh_CN“, „pt“) auf eine unterstützte Sprache ab.
    public static func resolve(_ code: String) -> String {
        if supportedLanguages.contains(code) { return code }
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if supportedLanguages.contains(normalized) { return normalized }
        let preferred = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: [normalized])
        if let first = preferred.first, first != developmentLanguage || normalized.hasPrefix("en") { return first }
        // Traditionelles Chinesisch (zh-Hant, zh-TW, zh-HK) bleibt bewusst bei
        // Englisch; vereinfachtes Chinesisch erkennt Foundation oben selbst.
        let base = String(normalized.prefix { $0 != "-" })
        if base == "pt" { return "pt-BR" }
        return supportedLanguages.first { $0 == base } ?? developmentLanguage
    }

    /// Aktuelle Sprache der Oberfläche.
    public static var language: String { override ?? processLanguage ?? automaticLanguage }

    /// Ob die Sprache von außen festgelegt ist (Test oder `--language`).
    private static var isPinned: Bool { override != nil || processLanguage != nil }

    /// Locale für Zahlen, Größen, Prozent und Datum. Automatisch: das Locale
    /// des Systems (Region, Dezimaltrenner); bei fester Sprache deren Locale.
    public static var locale: Locale {
        isPinned ? Locale(identifier: language) : Locale.current
    }

    /// Locale der Sprache selbst; bestimmt die Pluralregeln in `.stringsdict`.
    public static var languageLocale: Locale { Locale(identifier: language) }

    // MARK: Bundles

    /// Bundle mit den `.lproj`-Ordnern (siehe Typbeschreibung).
    public static let bundle: Bundle = {
        if Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                            forLocalization: developmentLanguage) != nil {
            return Bundle.main
        }
        return Bundle.module
    }()

    /// Bundles je Sprache. Die Ordnernamen werden normalisiert verglichen:
    /// Der Build mit Xcode legt z. B. `pt-BR.lproj` und `zh-Hans.lproj` als
    /// `pt_BR.lproj` bzw. in anderer Schreibweise ab (in der CI beobachtet).
    private static let languageBundles: [String: Bundle] = {
        func norm(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "-").lowercased() }
        var found: [String: String] = [:]
        for path in bundle.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            found[norm(((path as NSString).lastPathComponent as NSString).deletingPathExtension)] = path
        }
        var out: [String: Bundle] = [:]
        for code in supportedLanguages {
            if let path = found[norm(code)], let b = Bundle(path: path) { out[code] = b }
        }
        return out
    }()

    /// Bundle einer einzelnen Sprache (für Tests und die Sprachwahl).
    public static func bundle(for language: String) -> Bundle? { languageBundles[language] }

    private static let missing = "\u{1}missing\u{1}"

    /// Rohtext (bzw. Formatvorlage) zu `key` in `language`; Rückfall Englisch,
    /// dann der Schlüssel selbst.
    public static func raw(_ key: String, language: String) -> String {
        if let b = languageBundles[language] {
            let s = b.localizedString(forKey: key, value: missing, table: nil)
            if s != missing { return s }
        }
        if language != developmentLanguage, let en = languageBundles[developmentLanguage] {
            let s = en.localizedString(forKey: key, value: missing, table: nil)
            if s != missing { return s }
        }
        return key
    }

    /// Lokalisierter Text in der aktuellen Sprache.
    public static func string(_ key: String) -> String { raw(key, language: language) }

    /// Lokalisierter, formatierter Text. Zahlen für Pluralformen werden als
    /// `Int` übergeben, alles Sichtbare vorher formatiert als `String` (`%@`).
    public static func format(_ key: String, _ args: [any CVarArg]) -> String {
        format(key, args, language: language)
    }

    /// Wie `format(_:_:)`, aber in einer bestimmten Sprache. Das Locale der
    /// Sprache bestimmt die Pluralform.
    public static func format(_ key: String, _ args: [any CVarArg], language: String) -> String {
        String(format: raw(key, language: language), locale: Locale(identifier: language), arguments: args)
    }
}

/// Kurzform für `L10n.string(_:)`.
public func L(_ key: String) -> String { L10n.string(key) }

/// Kurzform für `L10n.format(_:_:)`.
public func L(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args) }

extension L10n {
    /// „1 file“, „312,841 files“ (Pluralform der Sprache, Zahl im Locale).
    public static func files(_ n: Int) -> String { L("count.files", n, ByteFormat.count(n)) }

    /// Fehlertext für die Oberfläche: eigene Fehler mit ihrer (lokalisierten)
    /// Beschreibung, Systemfehler mit `localizedDescription`.
    public static func describe(_ error: any Error) -> String {
        switch error {
        case let e as ScanError: e.description
        case let e as SnapshotError: e.description
        default: error.localizedDescription
        }
    }
}
