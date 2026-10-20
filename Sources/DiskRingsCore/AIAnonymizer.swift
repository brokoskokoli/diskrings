import Foundation

/// Anonymisiert Pfade und Namen, bevor sie in einen KI-Prompt gehen
/// (dev/DECISIONS.md, „Mit KI analysieren“): der Home-Ordner wird zu `~`,
/// Benutzername, voller Name (auch Vor- und Nachname einzeln) und Rechnername
/// werden durch eindeutige Platzhalter ersetzt.
///
/// Ersetzt wird nur an Token-Grenzen (davor und danach kein Buchstabe und
/// keine Ziffer, Unicode-bewusst), ohne Groß-/Kleinschreibung, aber mit
/// exakten diakritischen Zeichen („Jörg“ trifft „jörg“, nicht „Jorg“). Ein
/// angehängtes Genitiv-s („Stefans“, „Stefan’s“) zählt mit, damit
/// „Stefans MacBook Pro“ nicht durchrutscht; das „s“ bleibt hinter dem
/// Platzhalter stehen. Namen unter drei Zeichen und allgemeine Namen
/// („admin“, „user“ …) werden nicht ersetzt, damit z. B. der Benutzer „max“
/// nicht „maximum“ zerstört und „test“ nicht jede Testdatei verfremdet.
public struct PromptAnonymizer: Sendable, Equatable {
    public static let userPlaceholder = "<user>"
    public static let namePlaceholder = "<name>"
    public static let computerPlaceholder = "<computer>"

    /// Allgemeine Namen, die nie ersetzt werden (klein geschrieben).
    public static let genericNames: Set<String> = [
        "admin", "administrator", "user", "users", "dev", "developer", "test", "tester", "guest", "root",
        "mac", "macbook", "imac", "home", "shared", "owner", "apple", "staff", "demo", "default", "local",
        "library", "public", "work", "office", "macmini", "studio", "pro", "air", "the", "and",
    ]

    /// Home-Ordner ohne abschließenden Schrägstrich.
    public let home: String
    /// Zu ersetzende Tokens mit Platzhalter, längste zuerst.
    let tokens: [(token: String, placeholder: String)]

    public static func == (a: PromptAnonymizer, b: PromptAnonymizer) -> Bool {
        a.home == b.home && a.tokens.map(\.token) == b.tokens.map(\.token)
            && a.tokens.map(\.placeholder) == b.tokens.map(\.placeholder)
    }

    public init(home: String, userName: String?, fullName: String?, computerName: String?) {
        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        self.home = h
        var list: [(String, String)] = []
        func add(_ raw: String?, _ placeholder: String) {
            guard let raw else { return }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, !Self.genericNames.contains(t.lowercased()) else { return }
            // Ein Token muss mit einem Buchstaben oder einer Ziffer beginnen und enden,
            // sonst greifen die Grenzen nicht sinnvoll.
            guard let f = t.unicodeScalars.first, let l = t.unicodeScalars.last,
                  Self.isWordScalar(f), Self.isWordScalar(l) else { return }
            if list.contains(where: { $0.0.lowercased() == t.lowercased() }) { return }
            list.append((t, placeholder))
        }
        add(computerName, Self.computerPlaceholder)
        add(fullName, Self.namePlaceholder)
        add(userName, Self.userPlaceholder)
        if let fullName {
            let parts = fullName.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" })
            for p in parts { add(String(p), Self.namePlaceholder) }
        }
        tokens = list.sorted { $0.0.count > $1.0.count }
    }

    /// Pfad für den Prompt: Home-Präfix (an einer Komponentengrenze) wird zu
    /// `~`, danach werden Namen ersetzt.
    public func displayPath(_ path: String) -> String {
        var p = path
        if home.count > 1 {
            if p == home {
                p = "~"
            } else if p.hasPrefix(home + "/") {
                p = "~" + p.dropFirst(home.count)
            }
        }
        return anonymize(p)
    }

    /// Ersetzt Benutzer-, Personen- und Rechnernamen in einem beliebigen Text
    /// (Datei- und Ordnernamen, Pfade, Bundle-IDs).
    public func anonymize(_ text: String) -> String {
        guard !tokens.isEmpty, !text.isEmpty else { return text }
        var out = text
        for (token, placeholder) in tokens {
            out = Self.replace(token, with: placeholder, in: out)
        }
        return out
    }

    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic || s.properties.numericType != nil
    }

    private static func isWord(_ c: Character) -> Bool {
        c.unicodeScalars.contains { isWordScalar($0) }
    }

    /// Ersetzt alle Vorkommen von `token` an Token-Grenzen.
    static func replace(_ token: String, with placeholder: String, in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let r = rest.range(of: token, options: [.caseInsensitive]) {
            let before = r.lowerBound > rest.startIndex ? rest[rest.index(before: r.lowerBound)] : nil
            // Grenze davor: Anfang des Restes zählt nur am Anfang des ganzen
            // Textes oder nach einem bereits übernommenen Nicht-Wortzeichen.
            let prevChar = before ?? result.last
            var end = r.upperBound
            var suffix = ""
            // Genitiv: „s“, „'s“, „’s“ direkt danach.
            if end < rest.endIndex {
                let c = rest[end]
                if c == "s" || c == "S" {
                    let after = rest.index(after: end)
                    if after == rest.endIndex || !isWord(rest[after]) {
                        suffix = String(c)
                        end = after
                    }
                } else if c == "'" || c == "’" {
                    let s = rest.index(after: end)
                    if s < rest.endIndex, rest[s] == "s" || rest[s] == "S" {
                        let after = rest.index(after: s)
                        if after == rest.endIndex || !isWord(rest[after]) {
                            suffix = String(rest[end ..< after])
                            end = after
                        }
                    }
                }
            }
            let next: Character? = end < rest.endIndex ? rest[end] : nil
            let okBefore = prevChar.map { !isWord($0) } ?? true
            let okAfter = next.map { !isWord($0) } ?? true
            if okBefore && okAfter {
                result += rest[rest.startIndex ..< r.lowerBound]
                result += placeholder + suffix
                rest = rest[end...]
            } else {
                // Kein Treffer an einer Grenze: ein Zeichen weiter suchen.
                let step = rest.index(after: r.lowerBound)
                result += rest[rest.startIndex ..< step]
                rest = rest[step...]
            }
        }
        result += rest
        return result
    }
}
