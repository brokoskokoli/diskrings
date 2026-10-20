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

    /// Stufen, die den kompakten Prompt nacheinander verkürzen.
    static var reductionSteps: [AIPromptBuilder.Limits] {
        var steps: [AIPromptBuilder.Limits] = []
        for n in stride(from: 10, through: 0, by: -1) {
            steps.append(.init(largest: n, includeTypes: false))
        }
        steps.append(.init(largest: 5, includeTypes: false, includeOptional: false, nameLimit: 60))
        steps.append(.init(largest: 0, includeTypes: false, includeOptional: false, nameLimit: 60))
        steps.append(.init(largest: 0, includeTypes: false, includeOptional: false, nameLimit: 24))
        return steps
    }

    /// URL für einen Dienst mit Prompt-Parameter; `nil` bei `copyAndOpen`.
    /// Die Liste der größten Elemente wird gekürzt, bis die URL höchstens
    /// `maxLength` Zeichen hat; reicht das nicht, wird der Prompt hart
    /// abgeschnitten (an Zeichengrenzen).
    public static func prefillURL(for service: AIWebService, facts: AIPromptFacts,
                                  maxLength: Int = maxURLLength) -> URL? {
        guard case .prefill(let prefix) = service.handoff else { return nil }
        let budget = maxLength - prefix.count
        guard budget > 0 else { return nil }
        var prompt = ""
        for step in reductionSteps {
            prompt = AIPromptBuilder.prompt(facts, style: .compact, limits: step)
            if encode(prompt).count <= budget { return URL(string: prefix + encode(prompt)) }
        }
        return URL(string: prefix + fit(prompt, budget: budget))
    }

    /// Kodierter Prompt, der höchstens `budget` Zeichen lang ist.
    static func fit(_ prompt: String, budget: Int) -> String {
        var chars = Array(prompt)
        var encoded = encode(prompt)
        // Grob kürzen (Verhältnis), dann zeichenweise.
        while encoded.count > budget, !chars.isEmpty {
            let ratio = Double(budget) / Double(encoded.count)
            let target = max(0, min(chars.count - 1, Int(Double(chars.count) * ratio) - 1))
            chars = Array(chars.prefix(target))
            encoded = encode(String(chars) + "…")
        }
        return encoded
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
