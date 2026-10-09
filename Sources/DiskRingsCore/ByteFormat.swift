import Foundation

/// Formatierung von Größen, Anzahlen, Anteilen und Dauern, abhängig vom Locale.
///
/// Größen werden wie im Finder dezimal angegeben (1 KB = 1000 Byte).
/// Regeln: unter 1000 Byte ganze Bytes („512 bytes“), Kilobyte ohne
/// Nachkommastelle („4 KB“), ab Megabyte eine Nachkommastelle („1.2 MB“,
/// de „182,4 GB“, fr „182,4 Go“). Dezimal- und Tausendertrenner kommen aus dem
/// Locale, die Einheiten aus der Sprachtabelle (`unit.*`). Standard ist
/// `L10n.locale`; Tests geben das Locale fest vor.
public enum ByteFormat {
    private static let unitKeys = ["unit.kb", "unit.mb", "unit.gb", "unit.tb", "unit.pb", "unit.eb"]

    /// Geschütztes Leerzeichen zwischen Zahl und Einheit.
    public static let unitSeparator = "\u{00A0}"
    /// Echtes Minuszeichen für negative Werte.
    public static let minus = "\u{2212}"

    public static func string(_ bytes: UInt64, locale: Locale = L10n.locale) -> String {
        let style = Style.for(locale)
        if bytes < 1000 {
            return L10n.format("format.bytes", [Int(bytes), style.integer(bytes)], language: style.language)
        }
        // Ganzzahlig in Zehnteln der jeweiligen Einheit rechnen, damit nichts
        // durch Gleitkomma-Rundung kippt.
        var unit = 0
        var divisor: UInt64 = 1000
        while unit < unitKeys.count - 1, bytes / divisor >= 1000 {
            divisor *= 1000
            unit += 1
        }
        if unit == 0 {
            let kb = roundDiv(bytes, 1000)
            if kb < 1000 { return style.integer(kb) + unitSeparator + style.units[0] }
            // 999 500 Byte → „1.0 MB“
            return style.tenths(roundDiv(bytes, 100_000)) + unitSeparator + style.units[1]
        }
        var tenths = roundDiv(bytes, divisor / 10)
        if tenths >= 10_000, unit < unitKeys.count - 1 {
            unit += 1
            tenths = roundDiv(bytes, divisor * 100)
        }
        return style.tenths(tenths) + unitSeparator + style.units[unit]
    }

    /// Vorzeichenbehaftete Größe für Differenzen („+6.3 GB“, „−6.3 GB“, „0 bytes“).
    public static func signed(_ delta: Int64, locale: Locale = L10n.locale) -> String {
        if delta == 0 { return string(0, locale: locale) }
        let mag = string(delta.magnitude, locale: locale)
        return (delta > 0 ? "+" : minus) + mag
    }

    /// Anzahl mit Tausendertrennern des Locales (en „312,841“, de „312.841“, fr „312 841“).
    public static func count<I: BinaryInteger>(_ value: I, locale: Locale = L10n.locale) -> String {
        let out = Style.for(locale).integer(value.magnitude)
        return value < 0 ? minus + out : out
    }

    /// Anteil als Prozent („41 %“, unter 10 % mit einer Nachkommastelle: „0,5 %“);
    /// Stellung des Prozentzeichens wie im Locale (en „41%“, tr „%41“).
    public static func percent(_ fraction: Double, locale: Locale = L10n.locale) -> String {
        guard fraction.isFinite else { return "–" }
        let style = Style.for(locale)
        let p = fraction * 100
        let number: String
        let negative: Bool
        if p.magnitude < 9.95 {
            let tenths = Int64((p * 10).rounded())
            negative = tenths < 0
            number = style.tenths(tenths.magnitude)
        } else {
            let whole = Int64(p.rounded())
            negative = whole < 0
            number = style.integer(whole.magnitude)
        }
        return (negative ? minus : "") + style.percentPrefix + number + style.percentSuffix
    }

    /// Dauer in Sekunden („12.3 s“, „2 min 05 s“).
    public static func duration(_ seconds: Double, locale: Locale = L10n.locale) -> String {
        let style = Style.for(locale)
        if seconds < 60 {
            let t = style.tenths(UInt64((max(seconds, 0) * 10).rounded()))
            return L10n.format("format.duration.seconds", [t], language: style.language)
        }
        let total = Int(seconds.rounded())
        let s = total % 60
        return L10n.format("format.duration.minutes", [String(total / 60), (s < 10 ? "0" : "") + String(s)],
                           language: style.language)
    }

    private static func roundDiv(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (q, r) = a.quotientAndRemainder(dividingBy: b)
        return r * 2 >= b ? q + 1 : q
    }

    /// Trennzeichen, Prozentmuster und Einheiten je Locale (zwischengespeichert).
    struct Style: Sendable {
        let language: String
        let decimal: String
        let group: String
        let percentPrefix: String
        let percentSuffix: String
        let units: [String]

        private static let lock = NSLock()
        nonisolated(unsafe) private static var cache: [String: Style] = [:]

        static func `for`(_ locale: Locale) -> Style {
            let id = locale.identifier
            if let s = lock.withLock({ cache[id] }) { return s }
            let s = Style(locale: locale)
            lock.withLock { cache[id] = s }
            return s
        }

        private init(locale: Locale) {
            language = L10n.resolve(locale.identifier)
            decimal = locale.decimalSeparator ?? "."
            group = locale.groupingSeparator ?? ""
            // Muster aus 0,5 → „50 %“, „50%“, „%50“ ableiten.
            let sample = (0.5).formatted(.percent.precision(.fractionLength(0)).locale(locale))
            if let r = sample.range(of: "50") {
                percentPrefix = String(sample[..<r.lowerBound])
                percentSuffix = String(sample[r.upperBound...])
            } else {
                percentPrefix = ""
                percentSuffix = ByteFormat.unitSeparator + "%"
            }
            let lang = language
            units = ByteFormat.unitKeys.map { L10n.raw($0, language: lang) }
        }

        func integer<I: BinaryInteger>(_ value: I) -> String {
            let digits = String(value)
            guard !group.isEmpty, digits.count > 3 else { return digits }
            var out = ""
            for (i, ch) in digits.enumerated() {
                if i > 0, (digits.count - i) % 3 == 0 { out += group }
                out.append(ch)
            }
            return out
        }

        func tenths(_ tenths: UInt64) -> String {
            integer(tenths / 10) + decimal + String(tenths % 10)
        }
    }
}
