@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Automatische Updates: wann der Updater (Sparkle) laufen darf")
struct UpdateConfigurationTests {
    /// Gültiger öffentlicher Ed25519-Schlüssel (32 Byte, base64), nur für Tests.
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    let feed = "https://github.com/brokoskokoli/diskrings/releases/latest/download/appcast.xml"
    let plain = AppEnvironment(isSandboxed: false)
    let app = "/Applications/DiskRings.app"

    /// Werte wie aus der Info.plist (`nil` = Schlüssel fehlt).
    struct Info { var feed: Any?; var key: Any? }
    func info(feed: Any? = nil, key: Any? = nil) -> Info { Info(feed: feed, key: key) }

    @Test("Vollständig konfiguriertes App-Bündel außerhalb der Sandbox: aktiv")
    func enabled() {
        let a = UpdateConfiguration.availability(info: info(feed: feed, key: key), bundlePath: app, environment: plain)
        #expect(a == .enabled)
        #expect(a.isEnabled)
    }

    @Test("Sandbox (App-Store-Variante): nie aktiv, auch wenn alles gesetzt ist")
    func sandboxed() {
        let a = UpdateConfiguration.availability(info: info(feed: feed, key: key), bundlePath: app,
                                                 environment: AppEnvironment(isSandboxed: true))
        #expect(a == .disabled(.sandboxed))
        #expect(!a.isEnabled)
    }

    @Test("Kein App-Bündel (swift run, Renderer, Tests): nicht aktiv")
    func notBundled() {
        for path in ["/Users/x/diskspace/.build/debug", "/usr/local/bin", "", "/Applications/DiskRings.appx"] {
            #expect(UpdateConfiguration.availability(info: info(feed: feed, key: key), bundlePath: path,
                                                     environment: plain) == .disabled(.notAppBundle), "\(path)")
        }
        // Endschrägstrich und Groß-/Kleinschreibung der Endung sind egal.
        #expect(UpdateConfiguration.availability(info: info(feed: feed, key: key), bundlePath: app + "/",
                                                 environment: plain) == .enabled)
        #expect(UpdateConfiguration.availability(info: info(feed: feed, key: key), bundlePath: "/A/DiskRings.APP",
                                                 environment: plain) == .enabled)
    }

    @Test("Ohne Info.plist bzw. ohne Feed-Adresse: nicht aktiv")
    func missingFeed() {
        #expect(UpdateConfiguration.availability(info: info(key: key), bundlePath: app, environment: plain)
            == .disabled(.missingFeedURL))
        #expect(UpdateConfiguration.availability(info: info(feed: "", key: key), bundlePath: app, environment: plain)
            == .disabled(.missingFeedURL))
        #expect(UpdateConfiguration.availability(info: info(feed: "   ", key: key), bundlePath: app, environment: plain)
            == .disabled(.missingFeedURL))
        // Falscher Typ zählt als fehlend.
        #expect(UpdateConfiguration.availability(info: info(feed: 42, key: key), bundlePath: app, environment: plain)
            == .disabled(.missingFeedURL))
    }

    @Test("Feed nur über HTTPS mit Host")
    func insecureFeed() {
        for bad in ["http://github.com/appcast.xml", "file:///tmp/appcast.xml", "ftp://x/appcast.xml",
                    "https://", "github.com/appcast.xml", "https:///appcast.xml"] {
            #expect(UpdateConfiguration.availability(info: info(feed: bad, key: key), bundlePath: app,
                                                     environment: plain) == .disabled(.insecureFeedURL), "\(bad)")
        }
        #expect(UpdateConfiguration.availability(info: info(feed: "HTTPS://example.org/a.xml", key: key),
                                                 bundlePath: app, environment: plain) == .enabled)
    }

    @Test("Ohne öffentlichen Schlüssel: nicht aktiv (Sparkle würde unsignierte Updates ablehnen)")
    func missingKey() {
        #expect(UpdateConfiguration.availability(info: info(feed: feed), bundlePath: app, environment: plain)
            == .disabled(.missingPublicKey))
        #expect(UpdateConfiguration.availability(info: info(feed: feed, key: ""), bundlePath: app, environment: plain)
            == .disabled(.missingPublicKey))
        #expect(UpdateConfiguration.availability(info: info(feed: feed, key: " \n"), bundlePath: app,
                                                 environment: plain) == .disabled(.missingPublicKey))
    }

    @Test("Ungültiger öffentlicher Schlüssel: nicht aktiv")
    func invalidKey() {
        let bad: [Any] = [
            "kein base64!",
            Data(repeating: 1, count: 31).base64EncodedString(),
            Data(repeating: 1, count: 33).base64EncodedString(),
            Data(repeating: 1, count: 64).base64EncodedString(), // privater Schlüssel (altes Format)
            String(Data(repeating: 1, count: 32).base64EncodedString().dropLast()),
            7,
        ]
        for k in bad {
            #expect(UpdateConfiguration.availability(info: info(feed: feed, key: k), bundlePath: app,
                                                     environment: plain) == .disabled(.invalidPublicKey), "\(k)")
        }
    }

    @Test("Schlüsselprüfung: genau 32 Byte base64, Leerraum am Rand egal")
    func keyValidation() {
        #expect(UpdateConfiguration.isValidPublicEDKey(key))
        #expect(UpdateConfiguration.isValidPublicEDKey(" \(key)\n"))
        #expect(!UpdateConfiguration.isValidPublicEDKey(""))
        #expect(!UpdateConfiguration.isValidPublicEDKey("AAAA"))
        #expect(!UpdateConfiguration.isValidPublicEDKey(key + key))
        // Ein Zeilenumbruch mitten im Schlüssel ist kein gültiger Wert für die Info.plist.
        let mid = key.index(key.startIndex, offsetBy: 10)
        #expect(!UpdateConfiguration.isValidPublicEDKey(key[..<mid] + "\n" + key[mid...]))
    }

    @Test("Reihenfolge der Gründe: Sandbox vor allem anderen, dann Bündel, Feed, Schlüssel")
    func precedence() {
        #expect(UpdateConfiguration.availability(info: info(), bundlePath: "", environment: AppEnvironment(isSandboxed: true))
            == .disabled(.sandboxed))
        #expect(UpdateConfiguration.availability(info: info(), bundlePath: "/x", environment: plain)
            == .disabled(.notAppBundle))
        #expect(UpdateConfiguration.availability(info: info(feed: "http://x"), bundlePath: app, environment: plain)
            == .disabled(.insecureFeedURL))
    }

    @Test("Die eingecheckte Schlüsseldatei ist leer/fehlt oder enthält einen gültigen Schlüssel")
    func repoKeyFile() throws {
        let url = SourceTree.root.appendingPathComponent("Resources/sparkle-public-ed-key.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            #expect(UpdateConfiguration.isValidPublicEDKey(trimmed))
        }
    }
}

extension UpdateConfiguration {
    /// Kurzform für die Tests oben.
    static func availability(info: UpdateConfigurationTests.Info, bundlePath: String,
                             environment: AppEnvironment) -> Availability {
        availability(feedURL: info.feed, publicKey: info.key, bundlePath: bundlePath, environment: environment)
    }
}

@Suite("Automatische Updates: Sparkle nur in der GitHub-Variante")
struct SparkleSeparationTests {
    @Test("Sparkle wird nur im App-Target und nur unter #if Updates importiert")
    func importsGuarded() {
        let files = SourceTree.swiftSources().filter { $0.text.contains("import Sparkle") }
        #expect(!files.isEmpty, "AppUpdater.swift sollte Sparkle importieren")
        for file in files {
            #expect(file.path.hasPrefix("Sources/DiskRings/"), "\(file.path): Sparkle nur in der App")
            // Jede Zeile `import Sparkle` liegt in einem `#if Updates`-Block.
            var depth: [Bool] = []
            for line in file.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#if ") { depth.append(t == "#if Updates") }
                else if t.hasPrefix("#endif") { _ = depth.popLast() }
                else if t == "import Sparkle" {
                    #expect(depth.contains(true), "\(file.path): import Sparkle außerhalb von #if Updates")
                }
            }
        }
    }

    @Test("Core enthält keine Sparkle-Zeichenketten (landen sonst im Store-Binary)")
    func coreHasNoSparkleStrings() {
        for file in SourceTree.swiftSources() where file.path.hasPrefix("Sources/DiskRingsCore/") {
            // Nur Code, keine Kommentare: Zeichenkettenliterale mit SU…-Schlüsseln oder Sparkle.
            for line in file.text.split(separator: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                for needle in ["\"SU", "Sparkle", "SPU"] where code.contains(needle) {
                    Issue.record("\(file.path): \(line)")
                }
            }
        }
    }

    @Test("Package.swift: Sparkle exakt gepinnt, nur über den Trait Updates, nur im App-Target")
    func manifest() throws {
        let text = try String(contentsOf: SourceTree.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(text.contains(#".package(url: "https://github.com/sparkle-project/Sparkle", exact: "#))
        #expect(text.contains(#".default(enabledTraits: ["Updates"])"#))
        #expect(text.contains(#".product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["Updates"]))"#))
        #expect(text.components(separatedBy: #"package: "Sparkle""#).count == 2, "Sparkle nur in einem Target")
    }
}
