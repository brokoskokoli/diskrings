/// Generationszähler für Hintergrundarbeit, deren Ergebnis nur übernommen
/// werden darf, wenn inzwischen nichts Neueres angestoßen oder verworfen
/// wurde (z. B. ein Vergleich, während ein neuer Scan beginnt).
///
///     let token = gate.begin()
///     … await Hintergrundarbeit …
///     guard gate.isCurrent(token) else { return } // verworfen
public struct GenerationGate: Sendable, Equatable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Neue Anfrage; ältere gelten danach als überholt.
    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Verwirft alle laufenden Anfragen.
    public mutating func invalidate() { generation &+= 1 }

    public func isCurrent(_ token: UInt64) -> Bool { token == generation }
}
