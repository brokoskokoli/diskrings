@testable import DiskRingsCore
import Testing

/// Abnahme-Befund: Ein im Hintergrund berechneter Vergleich durfte einen
/// inzwischen gestarteten neuen Scan überlagern. `GenerationGate` entscheidet,
/// ob ein Ergebnis noch übernommen werden darf.
@Suite("Generationszähler für Hintergrundarbeit")
struct GenerationGateTests {
    @Test("Nur das Ergebnis der jüngsten Anfrage gilt; invalidate verwirft alle laufenden")
    func gate() {
        var g = GenerationGate()
        let a = g.begin()
        #expect(g.isCurrent(a))
        let b = g.begin()
        #expect(!g.isCurrent(a), "ein neuer Vergleich ersetzt den alten")
        #expect(g.isCurrent(b))
        g.invalidate() // neuer Scan oder zurück zum Start
        #expect(!g.isCurrent(b))
        let c = g.begin()
        #expect(g.isCurrent(c) && !g.isCurrent(b) && !g.isCurrent(a))
    }

    @Test("Ablauf: Vergleich startet, Scan beginnt, Vergleich wird fertig → verworfen")
    func compareThenScan() {
        var g = GenerationGate()
        let compare = g.begin()
        g.invalidate() // startScan
        #expect(!g.isCurrent(compare))
    }
}
