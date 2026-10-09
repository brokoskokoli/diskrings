@testable import DiskRingsCore
import Testing

@Suite("Formatierung")
struct ByteFormatTests {
    let nb = "\u{00A0}"

    @Test("Bytes unter 1000", arguments: [(UInt64(0), "0"), (1, "1"), (512, "512"), (999, "999")])
    func smallBytes(value: UInt64, expected: String) {
        #expect(ByteFormat.string(value) == "\(expected)\(nb)Byte")
    }

    @Test("Kilobyte ohne Nachkommastelle")
    func kilobytes() {
        #expect(ByteFormat.string(1000) == "1\(nb)KB")
        #expect(ByteFormat.string(4096) == "4\(nb)KB")
        #expect(ByteFormat.string(1499) == "1\(nb)KB")
        #expect(ByteFormat.string(1500) == "2\(nb)KB")
        #expect(ByteFormat.string(999_499) == "999\(nb)KB")
    }

    @Test("Übergang KB → MB rundet sauber")
    func kbToMb() {
        #expect(ByteFormat.string(999_500) == "1,0\(nb)MB")
        #expect(ByteFormat.string(1_000_000) == "1,0\(nb)MB")
    }

    @Test("Dezimal mit Komma wie im Finder")
    func decimal() {
        #expect(ByteFormat.string(1_234_567) == "1,2\(nb)MB")
        #expect(ByteFormat.string(182_400_000_000) == "182,4\(nb)GB")
        #expect(ByteFormat.string(61_000_000_000) == "61,0\(nb)GB")
        #expect(ByteFormat.string(994_000_000_000) == "994,0\(nb)GB")
        #expect(ByteFormat.string(999_960_000_000) == "1,0\(nb)TB")
        #expect(ByteFormat.string(2_500_000_000_000) == "2,5\(nb)TB")
        #expect(ByteFormat.string(UInt64.max) == "18,4\(nb)EB")
    }

    @Test("Vorzeichen für Differenzen")
    func signed() {
        #expect(ByteFormat.signed(6_300_000_000) == "+6,3\(nb)GB")
        #expect(ByteFormat.signed(-6_300_000_000) == "\u{2212}6,3\(nb)GB")
        #expect(ByteFormat.signed(0) == "0\(nb)Byte")
        #expect(ByteFormat.signed(Int64.min).hasPrefix("\u{2212}"))
    }

    @Test("Anzahl mit Tausendertrennern")
    func count() {
        let g = "\u{202F}"
        #expect(ByteFormat.count(0) == "0")
        #expect(ByteFormat.count(999) == "999")
        #expect(ByteFormat.count(1000) == "1\(g)000")
        #expect(ByteFormat.count(312_841) == "312\(g)841")
        #expect(ByteFormat.count(1_234_567) == "1\(g)234\(g)567")
        #expect(ByteFormat.count(-1500) == "\u{2212}1\(g)500")
    }

    @Test("Prozent")
    func percent() {
        #expect(ByteFormat.percent(0.41) == "41\(nb)%")
        #expect(ByteFormat.percent(0.005) == "0,5\(nb)%")
        #expect(ByteFormat.percent(0) == "0,0\(nb)%")
        #expect(ByteFormat.percent(1) == "100\(nb)%")
        #expect(ByteFormat.percent(.nan) == "–")
    }

    @Test("Dauer")
    func duration() {
        #expect(ByteFormat.duration(12.34) == "12,3\(nb)s")
        #expect(ByteFormat.duration(125) == "2\(nb)min 05\(nb)s")
    }
}
