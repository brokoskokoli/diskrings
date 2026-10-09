/// Formatierung von Größen, Anzahlen und Anteilen auf Deutsch.
///
/// Größen werden wie im Finder dezimal angegeben (1 KB = 1000 Byte).
/// Regeln: unter 1000 Byte ganze Bytes („512 Byte“), Kilobyte ohne
/// Nachkommastelle („4 KB“), ab Megabyte eine Nachkommastelle mit Komma
/// („1,2 MB“, „182,4 GB“). Die Ausgabe ist unabhängig vom System-Locale.
public enum ByteFormat {
    private static let units = ["KB", "MB", "GB", "TB", "PB", "EB"]

    /// Geschütztes Leerzeichen zwischen Zahl und Einheit.
    public static let unitSeparator = "\u{00A0}"
    /// Schmales geschütztes Leerzeichen als Tausendertrenner („312 841“).
    public static let groupSeparator = "\u{202F}"
    /// Echtes Minuszeichen für negative Werte.
    public static let minus = "\u{2212}"

    public static func string(_ bytes: UInt64) -> String {
        if bytes < 1000 { return "\(bytes)\(unitSeparator)Byte" }
        // Ganzzahlig in Zehnteln der jeweiligen Einheit rechnen, damit nichts
        // durch Gleitkomma-Rundung kippt.
        var unit = 0
        var divisor: UInt64 = 1000
        while unit < units.count - 1, bytes / divisor >= 1000 {
            divisor *= 1000
            unit += 1
        }
        if unit == 0 {
            let kb = roundDiv(bytes, 1000)
            if kb < 1000 { return "\(kb)\(unitSeparator)KB" }
            // 999 500 Byte → „1,0 MB“
            return "\(formatTenths(roundDiv(bytes, 100_000)))\(unitSeparator)MB"
        }
        var tenths = roundDiv(bytes, divisor / 10)
        if tenths >= 10_000, unit < units.count - 1 {
            unit += 1
            tenths = roundDiv(bytes, divisor * 100)
        }
        return "\(formatTenths(tenths))\(unitSeparator)\(units[unit])"
    }

    /// Vorzeichenbehaftete Größe für Differenzen („+6,3 GB“, „−6,3 GB“, „0 Byte“).
    public static func signed(_ delta: Int64) -> String {
        if delta == 0 { return string(0) }
        let mag = string(delta.magnitude)
        return (delta > 0 ? "+" : minus) + mag
    }

    /// Anzahl mit Tausendertrennern („312 841“).
    public static func count<I: BinaryInteger>(_ value: I) -> String {
        let neg = value < 0
        let digits = String(value.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out += groupSeparator }
            out.append(ch)
        }
        return neg ? minus + out : out
    }

    /// Anteil als Prozent („41 %“, unter 10 % mit einer Nachkommastelle: „0,5 %“).
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "–" }
        let p = fraction * 100
        if p.magnitude < 9.95 {
            let tenths = Int64((p * 10).rounded())
            let sign = tenths < 0 ? minus : ""
            return "\(sign)\(formatTenths(tenths.magnitude))\(unitSeparator)%"
        }
        return "\(Int64(p.rounded()))\(unitSeparator)%"
    }

    /// Dauer in Sekunden („12,3 s“, „2 min 05 s“).
    public static func duration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(formatTenths(UInt64((max(seconds, 0) * 10).rounded())))\(unitSeparator)s"
        }
        let total = Int(seconds.rounded())
        let s = total % 60
        return "\(total / 60)\(unitSeparator)min \(s < 10 ? "0" : "")\(s)\(unitSeparator)s"
    }

    private static func roundDiv(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (q, r) = a.quotientAndRemainder(dividingBy: b)
        return r * 2 >= b ? q + 1 : q
    }

    private static func formatTenths(_ tenths: UInt64) -> String {
        "\(count(tenths / 10)),\(tenths % 10)"
    }
}
