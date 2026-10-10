/// Lokalisierte Trennzeichen für zusammengesetzte Texte (statt fester
/// Literale wie „: “ oder „ · “ im Code). Französisch z. B. setzt vor den
/// Doppelpunkt ein geschütztes Leerzeichen, Japanisch und Chinesisch einen
/// vollbreiten Doppelpunkt.
public enum TextFormat {
    /// „Bezeichnung: Wert“.
    public static func labeled(_ label: String, _ value: String) -> String {
        L("format.labelValue", label, value)
    }

    /// Teile einer Zeile mit dem Mittelpunkt getrennt („1.234 Dateien · 3,2 GB“).
    public static func inline(_ parts: [String]) -> String {
        parts.joined(separator: L("format.inlineSeparator"))
    }

    /// Das Trennzeichen allein, ohne umgebende Leerzeichen (für Layouts mit eigenem Abstand).
    public static var inlineSeparatorGlyph: String {
        let s = L("format.inlineSeparator").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? L("format.inlineSeparator") : s
    }

    /// Winkel in Grad („0,5°“); `value` ist schon nach Locale formatiert.
    public static func degrees(_ value: String) -> String {
        L("format.degrees", value)
    }
}
