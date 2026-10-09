import Foundation

/// Sprachwahl in den Einstellungen: „Automatisch (System)“ oder eine feste Sprache.
public enum LanguageChoice: Hashable, Sendable {
    case automatic
    case language(String)

    /// Alle Einträge der Auswahl in Anzeigereihenfolge.
    public static var all: [LanguageChoice] { [.automatic] + L10n.supportedLanguages.map { .language($0) } }

    /// Anzeigename: „Automatic (System)“ in der aktuellen Sprache, jede
    /// Sprache in ihrer eigenen Schreibweise („Deutsch“, „日本語“).
    public var title: String {
        switch self {
        case .automatic: L("settings.language.automatic")
        case .language(let code): L10n.nativeName(of: code)
        }
    }
}

/// Liest und schreibt die Sprache der App über den UserDefault
/// `AppleLanguages` in der Domain der App. Dieselbe Einstellung schreibt
/// macOS unter „Systemeinstellungen → Allgemein → Sprache & Region → Apps“;
/// beide Wege sehen also denselben Wert. Wirksam wird sie beim nächsten Start.
public struct LanguageSetting {
    public static let key = "AppleLanguages"

    private let defaults: UserDefaults
    private let domain: String

    /// - Parameters:
    ///   - defaults: `UserDefaults.standard` in der App, eine Suite in Tests.
    ///   - domain: Name der Domain (Bundle-ID bzw. Suite-Name). Nur aus ihr
    ///     wird gelesen, damit die globale Spracheinstellung nicht als Wahl gilt.
    public init(defaults: UserDefaults = .standard,
                domain: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) {
        self.defaults = defaults
        self.domain = domain
    }

    /// Gespeicherte Wahl; eine nicht unterstützte Sprache gilt als ihre nächste
    /// unterstützte Entsprechung, ein leerer Eintrag als „Automatisch“.
    public var choice: LanguageChoice {
        guard let list = defaults.persistentDomain(forName: domain)?[Self.key] as? [String],
              let first = list.first else { return .automatic }
        return .language(L10n.resolve(first))
    }

    /// Speichert die Wahl („Automatisch“ entfernt den Eintrag der App).
    public func set(_ choice: LanguageChoice) {
        switch choice {
        case .automatic: defaults.removeObject(forKey: Self.key)
        case .language(let code): defaults.set([code], forKey: Self.key)
        }
    }

    /// Ob für eine Wahl ein Neustart nötig ist: Die laufende App spricht
    /// `running`; „Automatisch“ braucht keinen, wenn die Systemsprache
    /// (`system`, ohne die Einstellung der App) schon gilt.
    public static func needsRestart(choice: LanguageChoice, running: String,
                                    system: String = L10n.systemLanguage) -> Bool {
        switch choice {
        case .automatic: system != running
        case .language(let code): code != running
        }
    }
}
