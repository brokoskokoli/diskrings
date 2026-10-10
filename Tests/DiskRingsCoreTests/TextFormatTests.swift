@testable import DiskRingsCore
import Foundation
import Testing

@Suite("Lokalisierte Trennzeichen (TextFormat)")
struct TextFormatTests {
    @Test("Englisch", .language("en"))
    func english() {
        #expect(TextFormat.labeled("Since 10/02", "used +3 GB") == "Since 10/02: used +3 GB")
        #expect(TextFormat.inline(["12 files", "3 GB"]) == "12 files · 3 GB")
        #expect(TextFormat.inline(["only"]) == "only")
        #expect(TextFormat.inline([]) == "")
        #expect(TextFormat.inlineSeparatorGlyph == "·")
        #expect(TextFormat.degrees("0.5") == "0.5°")
    }

    @Test("Französisch: geschütztes Leerzeichen vor dem Doppelpunkt", .language("fr"))
    func french() {
        #expect(TextFormat.labeled("Depuis", "x") == "Depuis\u{00A0}: x")
    }

    @Test("Japanisch und Chinesisch: vollbreiter Doppelpunkt", arguments: ["ja", "zh-Hans"])
    func cjk(lang: String) {
        L10n.$override.withValue(lang) {
            #expect(TextFormat.labeled("a", "b") == "a：b")
        }
    }

    @Test("Jede Sprache hat ein nicht leeres Trennzeichen und einen Doppelpunkt", arguments: L10n.supportedLanguages)
    func everyLanguage(lang: String) {
        L10n.$override.withValue(lang) {
            #expect(!TextFormat.inlineSeparatorGlyph.isEmpty)
            let s = TextFormat.labeled("A", "B")
            #expect(s.hasPrefix("A") && s.hasSuffix("B") && s.count > 2)
            #expect(TextFormat.degrees("1").contains("1"))
        }
    }
}
