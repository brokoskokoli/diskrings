import Foundation

/// Eine Web-KI für „Mit KI analysieren“. DiskRings öffnet nur den
/// Standardbrowser; eine eigene Netzwerkverbindung baut die App nicht auf.
public struct AIWebService: Sendable, Equatable, Identifiable {
    public enum Handoff: Sendable, Equatable {
        /// Prompt als URL-Parameter: `prefix` + URL-kodierter Prompt.
        case prefill(prefix: String)
        /// Kein offizieller Parameter: Prompt in die Zwischenablage, Startseite öffnen.
        case copyAndOpen
    }

    /// Stabile ID (Einstellungen), z. B. `web.claude`.
    public let id: String
    /// Name der Dienstes (Marke, nicht übersetzt).
    public let name: String
    /// Startseite.
    public let homeURL: String
    public let handoff: Handoff

    public init(id: String, name: String, homeURL: String, handoff: Handoff) {
        self.id = id
        self.name = name
        self.homeURL = homeURL
        self.handoff = handoff
    }
}

/// Katalog der Web-KIs in Menüreihenfolge (Quellen und Datum in dev/DECISIONS.md).
public enum AIWebCatalog {
    public static let all: [AIWebService] = [
        AIWebService(id: "web.claude", name: "Claude", homeURL: "https://claude.ai/new",
                     handoff: .prefill(prefix: "https://claude.ai/new?q=")),
        AIWebService(id: "web.chatgpt", name: "ChatGPT", homeURL: "https://chatgpt.com/",
                     handoff: .prefill(prefix: "https://chatgpt.com/?q=")),
        AIWebService(id: "web.gemini", name: "Gemini", homeURL: "https://gemini.google.com/app", handoff: .copyAndOpen),
        AIWebService(id: "web.perplexity", name: "Perplexity", homeURL: "https://www.perplexity.ai/",
                     handoff: .prefill(prefix: "https://www.perplexity.ai/search?q=")),
        AIWebService(id: "web.lechat", name: "Le Chat", homeURL: "https://chat.mistral.ai/chat",
                     handoff: .copyAndOpen),
        AIWebService(id: "web.duckai", name: "Duck.ai", homeURL: "https://duck.ai/", handoff: .copyAndOpen),
    ]

    public static func service(id: String) -> AIWebService? { all.first { $0.id == id } }
}

/// Links auf Web-KIs mit Längenbudget.
public enum AIWebLink {
    /// Höchstlänge der ganzen URL nach der Kodierung. Browser und Server
    /// vertragen deutlich mehr; 6000 bleibt sicher unter üblichen Grenzen
    /// (z. B. 8 KB Kopfzeile bei vielen Servern).
    public static let maxURLLength = 6000

    /// Zeichen, die im Wert eines Query-Parameters unkodiert bleiben dürfen
    /// (RFC 3986 „unreserved“). Alles andere, auch `&`, `=`, `+`, `#`,
    /// Leerzeichen und Zeilenumbrüche, wird prozentkodiert.
    static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s
    }()

    public static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Was beim Klick auf eine Web-KI passiert.
    public enum Opening: Sendable, Equatable {
        /// Prompt im Link.
        case prefill(URL)
        /// Prompt in die Zwischenablage, Startseite öffnen (Dienst ohne
        /// Parameter oder Prompt zu lang für den Link).
        case copyAndOpen(prompt: String, url: URL)
    }

    /// Der gesendete Prompt ist immer genau der von „Prompt kopieren“: Passt
    /// er kodiert nicht in `maxLength` Zeichen, wird er nicht gekürzt,
    /// sondern kopiert und die Startseite des Dienstes geöffnet.
    public static func open(for service: AIWebService, facts: AIPromptFacts,
                            maxLength: Int = maxURLLength) -> Opening? {
        let prompt = AIPromptBuilder.prompt(facts, style: .chat)
        guard let home = URL(string: service.homeURL) else { return nil }
        if case .prefill(let prefix) = service.handoff {
            let encoded = encode(prompt)
            if prefix.count + encoded.count <= maxLength, let url = URL(string: prefix + encoded) {
                return .prefill(url)
            }
        }
        return .copyAndOpen(prompt: prompt, url: home)
    }
}

/// Auswahl der KI-Einträge im Kontextmenü (Einstellungen → KI). Gespeichert
/// werden die **abgewählten** IDs: Neue Katalogeinträge sind so automatisch
/// an; gespeicherte IDs, die der Katalog nicht mehr kennt, werden ignoriert.
public struct AIMenuSelection: Sendable, Equatable {
    public private(set) var disabled: Set<String>
    public let known: Set<String>

    public init(stored: [String]?, known: [String]) {
        self.known = Set(known)
        disabled = Set(stored ?? []).intersection(self.known)
    }

    public func isEnabled(_ id: String) -> Bool { known.contains(id) && !disabled.contains(id) }

    public mutating func set(_ id: String, enabled: Bool) {
        guard known.contains(id) else { return }
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
    }

    public mutating func setAll(_ ids: [String], enabled: Bool) {
        for id in ids { set(id, enabled: enabled) }
    }

    /// Zum Speichern (sortiert, nur bekannte IDs).
    public var stored: [String] { disabled.sorted() }

    /// Ausgewählte Web-KIs in Katalogreihenfolge.
    public func enabledWebServices(_ catalog: [AIWebService] = AIWebCatalog.all) -> [AIWebService] {
        catalog.filter { isEnabled($0.id) }
    }
}

/// Getrennte Merker „Nicht mehr fragen“ für den Datenschutz-Hinweis: Web-KI
/// (Prompt im Link) und interaktive Sitzung (CLI liest den Ordner) sind
/// verschieden weitreichend. Der frühere gemeinsame Merker gilt nur für Web.
public struct AIConsentState: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case web, session
    }

    public private(set) var web: Bool
    public private(set) var session: Bool

    /// `legacy`: alter gemeinsamer Merker (nur noch für Web übernommen).
    public init(web: Bool?, session: Bool?, legacy: Bool? = nil) {
        self.web = web ?? legacy ?? false
        self.session = session ?? false
    }

    public func needsConsent(_ kind: Kind) -> Bool {
        switch kind {
        case .web: !web
        case .session: !session
        }
    }

    public mutating func dontAskAgain(_ kind: Kind) {
        switch kind {
        case .web: web = true
        case .session: session = true
        }
    }

    /// „Vor dem Senden erklären“ wieder an: beide Merker zurück.
    public mutating func reset() {
        web = false
        session = false
    }

    /// Ob überhaupt etwas zurückzusetzen ist (Schalter in den Einstellungen).
    public var asksAlways: Bool { !web && !session }
}

/// Ein Eintrag im Untermenü „Mit KI analysieren“ (die App macht daraus
/// Menüpunkte).
public enum AIMenuEntry: Sendable, Equatable {
    case web(AIWebService)
    /// Derselbe Prompt wie für die Web-KIs.
    case copyPrompt
    /// Überschrift „Interaktive Sitzung im Terminal“ (nicht wählbar).
    case sessionHeader
    /// Info-Zeilen (nicht wählbar): Suche läuft bzw. nichts gefunden.
    case sessionSearching
    case sessionNone
    /// Gefundene, ausgewählte CLI (ID aus dem CLI-Katalog).
    case sessionTool(id: String)
    case settings
}

/// Aufbau des Untermenüs: oben die ausgewählten Web-KIs und immer „Prompt
/// kopieren“, dann die CLI-Gruppe (nur GitHub-Variante außerhalb der
/// Sandbox), ganz unten „KI-Einstellungen …“. „Erneut suchen“ gibt es nur in
/// den Einstellungen.
public enum AIMenuPlan {
    /// Stand der CLI-Suche.
    public enum Sessions: Sendable, Equatable {
        case searching
        /// IDs der gefundenen CLIs in Katalogreihenfolge.
        case found([String])
    }

    /// `sessions == nil`: keine Sitzungen (App-Store-Variante, Sandbox).
    public static func groups(selection: AIMenuSelection, sessions: Sessions?,
                              webCatalog: [AIWebService] = AIWebCatalog.all) -> [[AIMenuEntry]] {
        var groups: [[AIMenuEntry]] = [selection.enabledWebServices(webCatalog).map { .web($0) } + [.copyPrompt]]
        switch sessions {
        case nil:
            break
        case .searching:
            groups.append([.sessionHeader, .sessionSearching])
        case .found(let ids) where ids.isEmpty:
            groups.append([.sessionHeader, .sessionNone])
        case .found(let ids):
            // Sind alle gefundenen abgewählt, fehlt die Gruppe ganz.
            let shown = ids.filter { selection.isEnabled($0) }
            if !shown.isEmpty { groups.append([.sessionHeader] + shown.map { .sessionTool(id: $0) }) }
        }
        groups.append([.settings])
        return groups
    }
}
