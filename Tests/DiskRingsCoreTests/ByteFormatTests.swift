@testable import DiskRingsCore
import Foundation
import Testing

/// Rundungsregeln mit deutschem Locale (wie bisher), danach dieselben Werte in
/// anderen Locales: Dezimal- und Tausendertrenner, Einheiten, Prozentzeichen.
@Suite("Formatierung", .language("de"))
struct ByteFormatTests {
    let nb = "\u{00A0}"
    let de = Locale(identifier: "de")

    @Test("Bytes unter 1000", arguments: [(UInt64(0), "0"), (1, "1"), (512, "512"), (999, "999")])
    func smallBytes(value: UInt64, expected: String) {
        #expect(ByteFormat.string(value, locale: de) == "\(expected)\(nb)Byte")
    }

    @Test("Kilobyte ohne Nachkommastelle")
    func kilobytes() {
        #expect(ByteFormat.string(1000, locale: de) == "1\(nb)KB")
        #expect(ByteFormat.string(4096, locale: de) == "4\(nb)KB")
        #expect(ByteFormat.string(1499, locale: de) == "1\(nb)KB")
        #expect(ByteFormat.string(1500, locale: de) == "2\(nb)KB")
        #expect(ByteFormat.string(999_499, locale: de) == "999\(nb)KB")
    }

    @Test("Übergang KB → MB rundet sauber")
    func kbToMb() {
        #expect(ByteFormat.string(999_500, locale: de) == "1,0\(nb)MB")
        #expect(ByteFormat.string(1_000_000, locale: de) == "1,0\(nb)MB")
    }

    @Test("Dezimal mit Komma wie im Finder")
    func decimal() {
        #expect(ByteFormat.string(1_234_567, locale: de) == "1,2\(nb)MB")
        #expect(ByteFormat.string(182_400_000_000, locale: de) == "182,4\(nb)GB")
        #expect(ByteFormat.string(61_000_000_000, locale: de) == "61,0\(nb)GB")
        #expect(ByteFormat.string(994_000_000_000, locale: de) == "994,0\(nb)GB")
        #expect(ByteFormat.string(999_960_000_000, locale: de) == "1,0\(nb)TB")
        #expect(ByteFormat.string(2_500_000_000_000, locale: de) == "2,5\(nb)TB")
        #expect(ByteFormat.string(UInt64.max, locale: de) == "18,4\(nb)EB")
    }

    @Test("Vorzeichen für Differenzen")
    func signed() {
        #expect(ByteFormat.signed(6_300_000_000, locale: de) == "+6,3\(nb)GB")
        #expect(ByteFormat.signed(-6_300_000_000, locale: de) == "\u{2212}6,3\(nb)GB")
        #expect(ByteFormat.signed(0, locale: de) == "0\(nb)Byte")
        #expect(ByteFormat.signed(Int64.min, locale: de).hasPrefix("\u{2212}"))
    }

    @Test("Anzahl mit Tausendertrennern des Locales")
    func count() {
        #expect(ByteFormat.count(0, locale: de) == "0")
        #expect(ByteFormat.count(999, locale: de) == "999")
        #expect(ByteFormat.count(1000, locale: de) == "1.000")
        #expect(ByteFormat.count(312_841, locale: de) == "312.841")
        #expect(ByteFormat.count(1_234_567, locale: de) == "1.234.567")
        #expect(ByteFormat.count(-1500, locale: de) == "\u{2212}1.500")
    }

    @Test("Prozent")
    func percent() {
        #expect(ByteFormat.percent(0.41, locale: de) == "41\(nb)%")
        #expect(ByteFormat.percent(0.005, locale: de) == "0,5\(nb)%")
        #expect(ByteFormat.percent(0, locale: de) == "0,0\(nb)%")
        #expect(ByteFormat.percent(1, locale: de) == "100\(nb)%")
        #expect(ByteFormat.percent(.nan, locale: de) == "–")
    }

    @Test("Dauer")
    func duration() {
        #expect(ByteFormat.duration(12.34, locale: de) == "12,3\(nb)s")
        #expect(ByteFormat.duration(125, locale: de) == "2\(nb)min 05\(nb)s")
    }

    @Test("Standard-Locale folgt der festen Sprache")
    func defaultLocale() {
        #expect(ByteFormat.string(182_400_000_000) == "182,4\(nb)GB")
        L10n.$override.withValue("en") {
            #expect(ByteFormat.string(182_400_000_000) == "182.4\(nb)GB")
        }
    }
}

@Suite("Formatierung je Locale")
struct LocaleFormatTests {
    let nb = "\u{00A0}"
    let nnb = "\u{202F}"

    func loc(_ id: String) -> Locale { Locale(identifier: id) }

    @Test("Größen: Dezimaltrenner und Einheiten")
    func sizes() {
        let v: UInt64 = 182_400_000_000
        #expect(ByteFormat.string(v, locale: loc("en")) == "182.4\(nb)GB")
        #expect(ByteFormat.string(v, locale: loc("en_US")) == "182.4\(nb)GB")
        #expect(ByteFormat.string(v, locale: loc("de_DE")) == "182,4\(nb)GB")
        #expect(ByteFormat.string(v, locale: loc("fr")) == "182,4\(nb)Go")
        #expect(ByteFormat.string(v, locale: loc("fr_CA")) == "182,4\(nb)Go")
        #expect(ByteFormat.string(v, locale: loc("ru")) == "182,4\(nb)ГБ")
        #expect(ByteFormat.string(v, locale: loc("ja")) == "182.4\(nb)GB")
        #expect(ByteFormat.string(v, locale: loc("zh-Hans")) == "182.4\(nb)GB")
        #expect(ByteFormat.string(v, locale: loc("pl")) == "182,4\(nb)GB")
    }

    @Test("Bytes mit Pluralform der Sprache")
    func bytes() {
        #expect(ByteFormat.string(1, locale: loc("en")) == "1\(nb)byte")
        #expect(ByteFormat.string(512, locale: loc("en")) == "512\(nb)bytes")
        #expect(ByteFormat.string(512, locale: loc("fr")) == "512\(nb)octets")
        #expect(ByteFormat.string(1, locale: loc("fr")) == "1\(nb)octet")
        #expect(ByteFormat.string(3, locale: loc("ru")) == "3\(nb)байта")
        #expect(ByteFormat.string(5, locale: loc("ru")) == "5\(nb)байт")
    }

    @Test("Tausendertrenner: en Komma, de Punkt, fr schmales geschütztes Leerzeichen")
    func grouping() {
        #expect(ByteFormat.count(312_841, locale: loc("en")) == "312,841")
        #expect(ByteFormat.count(312_841, locale: loc("de")) == "312.841")
        #expect(ByteFormat.count(312_841, locale: loc("fr")) == "312\(nnb)841")
        #expect(ByteFormat.count(312_841, locale: loc("ja")) == "312,841")
        #expect(ByteFormat.count(1_234_567, locale: loc("en")) == "1,234,567")
    }

    @Test("Prozent: Stellung und Abstand wie im Locale")
    func percent() {
        #expect(ByteFormat.percent(0.41, locale: loc("en")) == "41%")
        #expect(ByteFormat.percent(0.005, locale: loc("en")) == "0.5%")
        #expect(ByteFormat.percent(0.41, locale: loc("de")) == "41\(nb)%")
        #expect(ByteFormat.percent(0.41, locale: loc("fr")) == "41\(nb)%")
        #expect(ByteFormat.percent(0.41, locale: loc("tr")) == "%41")
        #expect(ByteFormat.percent(0.005, locale: loc("fr")) == "0,5\(nb)%")
    }

    @Test("Dauer je Sprache")
    func duration() {
        #expect(ByteFormat.duration(12.34, locale: loc("en")) == "12.3\(nb)s")
        #expect(ByteFormat.duration(125, locale: loc("en")) == "2\(nb)min 05\(nb)s")
        #expect(ByteFormat.duration(12.34, locale: loc("fr")) == "12,3\(nb)s")
    }

    @Test("Datum im Stil des Locales")
    func dates() throws {
        let tz = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_790_926_440) // 2026-10-02 07:34 UTC
        #expect(SnapshotNaming.longDate(date, timeZone: tz, locale: loc("de")) == "02.10.2026, 07:34")
        #expect(SnapshotNaming.longDate(date, timeZone: tz, locale: loc("en_US")).hasPrefix("Oct 2, 2026"))
        #expect(CompareHeadline.shortDate(date, timeZone: tz, locale: loc("de")) == "02.10., 07:34")
        #expect(CompareHeadline.shortDate(date, timeZone: tz, locale: loc("en_US")).hasPrefix("10/02"))
        #expect(CompareHeadline.shortDate(date, timeZone: tz, locale: loc("ja")).contains("10/02"))
    }
}
