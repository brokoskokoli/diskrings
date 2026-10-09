@testable import DiskRingsCore
import Foundation
import Testing

/// Quellbaum und Sprachdateien (die Tests lesen die eingecheckten Dateien,
/// nicht nur das gebaute Bündel).
enum SourceTree {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appendingPathComponent("Sources/DiskRingsCore/Resources")

    static func strings(_ lang: String, _ table: String = "Localizable") -> [String: String] {
        let url = resources.appendingPathComponent("\(lang).lproj/\(table).strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }

    static func plurals(_ lang: String) -> [String: [String: Any]] {
        let url = resources.appendingPathComponent("\(lang).lproj/Localizable.stringsdict")
        return (NSDictionary(contentsOf: url) as? [String: [String: Any]]) ?? [:]
    }

    /// Pluralvarianten eines Eintrags (`one`, `few`, … → Text).
    static func variants(_ entry: [String: Any]) -> [String: String] {
        guard let format = entry["NSStringLocalizedFormatKey"] as? String,
              let name = format.firstMatch(of: /%#@([a-z]+)@/)?.1,
              let rule = entry[String(name)] as? [String: String] else { return [:] }
        return rule.filter { !$0.key.hasPrefix("NSStringFormat") }
    }

    /// Alle Swift-Dateien unter `Sources/` mit Inhalt.
    static func swiftSources() -> [(path: String, text: String)] {
        let base = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.sorted { $0.path < $1.path }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map {
                (String(url.path.dropFirst(root.path.count + 1)), $0)
            }
        }
    }
}

/// Format-Platzhalter als sortierte Liste (Position, Typ); `%@` ohne Position
/// zählt fortlaufend.
func placeholders(_ s: String) -> [String] {
    var seq = 0
    var out: [String] = []
    for m in s.replacingOccurrences(of: "%%", with: "").matches(of: /%(\d+\$)?(@|lld|ld|d)/) {
        let pos: Int
        if let p = m.1 { pos = Int(p.dropLast()) ?? 0 } else { seq += 1; pos = seq }
        out.append("\(pos)\(m.2)")
    }
    return out.sorted()
}

@Suite("Lokalisierung: Sprachdateien")
struct LocalizationFileTests {
    let languages = L10n.supportedLanguages
    let base = SourceTree.strings("en")
    let basePlurals = SourceTree.plurals("en")

    @Test("Basis vorhanden und nicht leer")
    func baseExists() {
        #expect(base.count > 300)
        #expect(basePlurals.count > 15)
        #expect(L10n.developmentLanguage == "en")
        #expect(languages.first == "en")
    }

    @Test("Jede Sprache hat ein .lproj mit allen Dateien")
    func lprojFolders() throws {
        let dirs = try FileManager.default.contentsOfDirectory(atPath: SourceTree.resources.path)
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
        #expect(Set(dirs) == Set(languages))
        for lang in languages {
            for file in ["Localizable.strings", "Localizable.stringsdict", "InfoPlist.strings"] {
                let path = SourceTree.resources.appendingPathComponent("\(lang).lproj/\(file)").path
                #expect(FileManager.default.fileExists(atPath: path), "\(lang)/\(file)")
            }
        }
    }

    @Test("Vollständig: jede Sprache enthält alle Schlüssel der Basis, keine zusätzlichen")
    func completeness() {
        for lang in languages {
            let t = SourceTree.strings(lang)
            let missing = Set(base.keys).subtracting(t.keys)
            let extra = Set(t.keys).subtracting(base.keys)
            #expect(missing.isEmpty, "\(lang) fehlt: \(missing.sorted())")
            #expect(extra.isEmpty, "\(lang) zusätzlich: \(extra.sorted())")
            for (k, v) in t where v.trimmingCharacters(in: .whitespaces).isEmpty {
                Issue.record("\(lang): leerer Text für \(k)")
            }
            let p = SourceTree.plurals(lang)
            #expect(Set(p.keys) == Set(basePlurals.keys), "\(lang): Pluralschlüssel weichen ab")
        }
    }

    @Test("Platzhalter stimmen in Anzahl, Position und Typ überein")
    func placeholderConsistency() {
        for lang in languages {
            let t = SourceTree.strings(lang)
            for (k, v) in base {
                guard let tv = t[k] else { continue }
                #expect(placeholders(tv) == placeholders(v), "\(lang) \(k): \(tv)")
            }
            let p = SourceTree.plurals(lang)
            for (k, entry) in basePlurals {
                let ref = placeholders(SourceTree.variants(entry)["other"] ?? "")
                #expect(!ref.isEmpty, "en \(k) ohne Platzhalter")
                for (cat, text) in SourceTree.variants(p[k] ?? [:]) {
                    #expect(placeholders(text) == ref, "\(lang) \(k).\(cat): \(text)")
                }
            }
        }
    }

    @Test("Pluralformen vorhanden (CLDR-Kategorien je Sprache)")
    func pluralCategories() {
        let required: [String: Set<String>] = [
            "pl": ["one", "few", "many", "other"], "ru": ["one", "few", "many", "other"],
            "ja": ["other"], "zh-Hans": ["other"], "ko": ["other"],
        ]
        for lang in languages {
            let need = required[lang] ?? ["one", "other"]
            for (k, entry) in SourceTree.plurals(lang) {
                let cats = Set(SourceTree.variants(entry).keys)
                #expect(need.isSubset(of: cats), "\(lang) \(k): \(cats.sorted())")
                let type = (entry[String((entry["NSStringLocalizedFormatKey"] as? String ?? "")
                    .firstMatch(of: /%#@([a-z]+)@/)?.1 ?? "")] as? [String: String])?["NSStringFormatValueTypeKey"]
                #expect(type == "ld", "\(lang) \(k): Werttyp \(type ?? "-")")
            }
        }
    }

    @Test("Pluralregeln greifen zur Laufzeit", arguments: [
        ("en", [1: "1 file", 2: "2 files"]),
        ("de", [1: "1 Datei", 3: "3 Dateien"]),
        ("ru", [1: "1 файл", 3: "3 файла", 5: "5 файлов", 21: "21 файл"]),
        ("pl", [1: "1 plik", 2: "2 pliki", 5: "5 plików", 22: "22 pliki"]),
    ])
    func pluralRuntime(lang: String, expected: [Int: String]) {
        L10n.$override.withValue(lang) {
            for (n, text) in expected {
                #expect(L10n.files(n).replacingOccurrences(of: "\u{00A0}", with: " ") == text, "\(lang) \(n)")
            }
        }
    }

    @Test("Datenschutz-Texte: InfoPlist.strings je Sprache mit denselben Schlüsseln wie make-app.sh")
    func infoPlistStrings() throws {
        let script = try String(contentsOf: SourceTree.root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        let keys = Set(script.matches(of: /<key>(NS[A-Za-z]+UsageDescription)<\/key>/).map { String($0.1) })
        #expect(keys.count >= 8)
        for lang in languages {
            let t = SourceTree.strings(lang, "InfoPlist")
            #expect(Set(t.keys) == keys, "\(lang): \(Set(t.keys).symmetricDifference(keys).sorted())")
        }
        // Die englische Basis steht auch direkt in der Info.plist.
        for (k, v) in SourceTree.strings("en", "InfoPlist") {
            #expect(script.contains("<key>\(k)</key><string>\(v)</string>"), "\(k) weicht in make-app.sh ab")
        }
    }

    @Test("Laufzeit-Bündel enthält jede Sprache")
    func runtimeBundles() {
        for lang in languages {
            #expect(L10n.bundle(for: lang) != nil, "\(lang)")
            #expect(L10n.raw("menu.chooseFolder", language: lang) != "menu.chooseFolder", "\(lang)")
        }
    }
}

@Suite("Lokalisierung: Schlüssel im Code")
struct LocalizationKeyUsageTests {
    let sources = SourceTree.swiftSources()
    let base = SourceTree.strings("en")
    let basePlurals = SourceTree.plurals("en")

    /// Alle Schlüssel, die der Code über `L("…")` bzw. `L10n.string/format/raw("…")` anfragt.
    var requested: Set<String> {
        var out: Set<String> = []
        for (_, text) in sources {
            for m in text.matches(of: /\bL(?:10n\.(?:string|format|raw))?\("([A-Za-z0-9_.]+)"/) {
                out.insert(String(m.1))
            }
        }
        return out
    }

    @Test("Jeder angefragte Schlüssel existiert in der Basis")
    func requestedKeysExist() {
        let all = Set(base.keys).union(basePlurals.keys)
        let missing = requested.subtracting(all)
        #expect(missing.isEmpty, "fehlende Schlüssel: \(missing.sorted())")
        #expect(requested.count > 250)
    }

    @Test("Keine verwaisten Schlüssel: jeder Schlüssel steht als Literal im Code")
    func noOrphans() {
        let code = sources.map(\.text).joined(separator: "\n")
        for key in Set(base.keys).union(basePlurals.keys) {
            #expect(code.contains("\"\(key)\""), "verwaist: \(key)")
        }
    }

    @Test("Schlüssel sind stabile IDs (nur Kleinbuchstaben, Ziffern, Punkte, camelCase)")
    func keyShape() {
        for key in Set(base.keys).union(basePlurals.keys) {
            #expect(key.wholeMatch(of: /[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+/) != nil, "\(key)")
        }
    }
}

@Suite("Lokalisierung: keine fest verdrahteten deutschen Texte")
struct HardcodedGermanTests {
    /// Begründete Ausnahmen: Datei-Suffix und ein Ausschnitt der Zeile.
    static let allowlist: [(file: String, contains: String, reason: String)] = [
        ("Localization/L10n.swift", "case \"de\": \"Deutsch\"", "Sprachname in eigener Schreibweise für die Sprachwahl"),
        ("Localization/L10n.swift", "case \"tr\": \"Türkçe\"", "Sprachname in eigener Schreibweise für die Sprachwahl"),
        ("Localization/L10n.swift", "case \"fr\": \"Français\"", "Sprachname in eigener Schreibweise für die Sprachwahl"),
        ("Localization/L10n.swift", "case \"es\": \"Español\"", "Sprachname in eigener Schreibweise für die Sprachwahl"),
        ("Localization/L10n.swift", "case \"pt-BR\": \"Português (Brasil)\"", "Sprachname in eigener Schreibweise"),
    ]

    /// Zeilen mit diesen Aufrufen sind interne Diagnosen (Invarianten-Prüfung,
    /// Absturzmeldung, `ScanTree.validate`) und erscheinen nie in der Oberfläche.
    static let diagnosticCalls = ["precondition(", "fatalError(", "report(", "assert("]

    static var germanWords: Regex<(Substring, Substring)> { /\b(und|nicht|der|die|das|ist|wird|werden|wurde|ein|eine|einen|mit|für|von|oder|auf|nur|noch|bereits|kein|keine|Ordner|Datei|Dateien|Objekt|Objekte|Abbrechen|Löschen|Fehler|Zurück|Fertig|Schließen|Einstellungen|Größe|belegt|frei|Knoten|Wurzel|Papierkorb|Vergleich|gespeichert|fehlgeschlagen|Sichern|wählen|anzeigen|zeigen|öffnen|Speicher|Volumes? belegt)\b/ }

    /// Inhalte der String-Literale einer Swift-Datei mit Zeilennummer; Kommentare
    /// werden übersprungen, mehrzeilige Literale (`"""`) als Inhalt behandelt.
    static func literals(_ text: String) -> [(line: Int, code: String, value: String)] {
        var out: [(Int, String, String)] = []
        var multiline = false
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains("\"\"\"") {
                multiline.toggle()
                continue
            }
            if multiline { out.append((i + 1, line, line)); continue }
            if trimmed.hasPrefix("//") { continue }
            var inString = false, escaped = false, current = "", prev: Character = " "
            for ch in line {
                if inString {
                    if escaped { escaped = false; current.append(ch) } else if ch == "\\" { escaped = true; current.append(ch) } else if ch == "\"" {
                        out.append((i + 1, line, current)); current = ""; inString = false
                    } else { current.append(ch) }
                } else {
                    if ch == "/" && prev == "/" { break }
                    if ch == "\"" { inString = true }
                }
                prev = ch
            }
        }
        return out
    }

    @Test("Swift-Code ohne deutsche UI-Strings (Ausnahmen begründet)")
    func noGermanLiterals() {
        var findings: [String] = []
        for (path, text) in SourceTree.swiftSources() {
            for (line, code, value) in Self.literals(text) {
                let german = value.contains(where: { "äöüÄÖÜß„“‚‘".contains($0) }) || value.firstMatch(of: Self.germanWords) != nil
                guard german else { continue }
                if Self.diagnosticCalls.contains(where: { code.contains($0) }) { continue }
                if Self.allowlist.contains(where: { path.hasSuffix($0.file) && code.contains($0.contains) }) { continue }
                findings.append("\(path):\(line): \(value)")
            }
        }
        #expect(findings.isEmpty, "\(findings.count) Funde:\n\(findings.joined(separator: "\n"))")
    }

    @Test("Der Detektor findet deutsche Texte (Gegenprobe)")
    func detectorWorks() {
        let sample = """
        let a = Text("Ordner wählen")  // „Kommentar“ zählt nicht
        // Text("Löschen")
        let b = L("menu.chooseFolder")
        precondition(x, "Knoten lebt nicht")
        """
        let hits = Self.literals(sample).filter {
            $0.value.contains(where: { "äöüÄÖÜß„“".contains($0) }) || $0.value.firstMatch(of: Self.germanWords) != nil
        }
        #expect(hits.map(\.value) == ["Ordner wählen", "Knoten lebt nicht"])
    }
}

@Suite("Lokalisierung: Sprachwahl")
struct LanguageSelectionTests {
    @Test("Sprachcodes werden auf unterstützte Sprachen abgebildet")
    func resolve() {
        #expect(L10n.resolve("de") == "de")
        #expect(L10n.resolve("de-AT") == "de")
        #expect(L10n.resolve("fr-CA") == "fr")
        #expect(L10n.resolve("fr_FR") == "fr")
        #expect(L10n.resolve("pt") == "pt-BR")
        #expect(L10n.resolve("pt-PT") == "pt-BR")
        #expect(L10n.resolve("zh-Hans-CN") == "zh-Hans")
        #expect(L10n.resolve("zh-CN") == "zh-Hans")
        #expect(L10n.resolve("zh") == "zh-Hans")
        #expect(L10n.resolve("zh-Hant") == "en")
        #expect(L10n.resolve("zh-TW") == "en")
        #expect(L10n.resolve("en-GB") == "en")
        #expect(L10n.resolve("cs") == "en")
        #expect(L10n.resolve("xx") == "en")
    }

    @Test("Bevorzugte Sprache: erste unterstützte, sonst Englisch")
    func preferred() {
        #expect(L10n.preferredSupported(["cs-CZ", "ru-RU", "en"]) == "ru")
        #expect(L10n.preferredSupported(["cs-CZ", "hu"]) == "en")
        #expect(L10n.preferredSupported(["en-US", "de"]) == "en")
        #expect(L10n.preferredSupported(["ja-JP"]) == "ja")
        #expect(L10n.preferredSupported([]) == "en")
    }

    @Test("Feste Sprache für einen Task, Rückfall auf Englisch für fehlende Schlüssel")
    func overrideAndFallback() {
        L10n.$override.withValue("fr") {
            #expect(L10n.language == "fr")
            #expect(L("action.revealInFinder") == "Afficher dans le Finder")
            #expect(L10n.locale.identifier == "fr")
        }
        L10n.$override.withValue("de") {
            #expect(L("action.moveToTrash") == "In den Papierkorb legen")
            #expect(L("does.not.exist") == "does.not.exist")
        }
        #expect(L10n.raw("does.not.exist", language: "ru") == "does.not.exist")
    }

    @Test("Sprachnamen in eigener Schreibweise, Auswahl mit „Automatisch“ zuerst")
    func choices() {
        #expect(L10n.nativeName(of: "de") == "Deutsch")
        #expect(L10n.nativeName(of: "ja") == "日本語")
        #expect(L10n.nativeName(of: "zh-Hans") == "简体中文")
        #expect(L10n.nativeName(of: "ru") == "Русский")
        #expect(LanguageChoice.all.first == .automatic)
        #expect(LanguageChoice.all.count == L10n.supportedLanguages.count + 1)
        L10n.$override.withValue("en") { #expect(LanguageChoice.automatic.title == "Automatic (System)") }
        L10n.$override.withValue("de") { #expect(LanguageChoice.language("fr").title == "Français") }
    }

    @Test("Einstellung über AppleLanguages der App-Domain")
    func setting() throws {
        let suite = "DiskRingsLanguageTest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = LanguageSetting(defaults: defaults, domain: suite)
        #expect(s.choice == .automatic)
        s.set(.language("fr"))
        #expect(s.choice == .language("fr"))
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["fr"])
        s.set(.language("ja"))
        #expect(s.choice == .language("ja"))
        s.set(.automatic)
        #expect(s.choice == .automatic)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        // Von den Systemeinstellungen geschrieben (Sprache pro App), z. B. „fr-CA“.
        defaults.set(["fr-CA", "en"], forKey: "AppleLanguages")
        #expect(s.choice == .language("fr"))
    }

    @Test("Neustart nur, wenn sich die Sprache wirklich ändert")
    func restart() {
        #expect(LanguageSetting.needsRestart(choice: .language("fr"), running: "de", system: "de"))
        #expect(!LanguageSetting.needsRestart(choice: .language("de"), running: "de", system: "en"))
        #expect(!LanguageSetting.needsRestart(choice: .automatic, running: "de", system: "de"))
        #expect(LanguageSetting.needsRestart(choice: .automatic, running: "fr", system: "de"))
    }
}
