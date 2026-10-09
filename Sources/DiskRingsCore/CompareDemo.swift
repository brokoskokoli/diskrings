import Darwin
import Foundation

/// Beispiel für den Vergleichsmodus (gerenderte Vorschauen mit
/// `--render-snapshots <ordner> --compare-demo` und Tests): Ein kleines
/// Home-Verzeichnis wird in einem **übergebenen** (temporären) Ordner
/// angelegt und danach verändert: ein neuer großer Ordner in Downloads,
/// gewachsene Caches und Build-Ordner, eine neue Datei, gelöschte Filme und
/// ein gelöschtes Album, eine verkleinerte Datei.
///
/// Es wird ausschließlich unterhalb von `root` geschrieben und gelöscht.
public enum CompareDemo {
    static let MB = 1_000_000

    /// Der neue große Ordner („Größte Veränderungen“ zeigt ihn an erster Stelle).
    public static let newFolder = "Downloads/Xcode-26-Beta"
    /// Sein Elternordner (dominiert im Wachstums-Sunburst).
    public static let newFolderParent = "Downloads"

    /// Ausgangszustand (rund 190 MB).
    public static func createInitial(at root: String) throws {
        let files: [(String, Int)] = [
            ("Downloads/alt-installer.dmg", 24), ("Downloads/foto-export.zip", 12), ("Downloads/rechnung.pdf", 2),
            ("Library/Caches/com.apple.Safari/cache-1.db", 6), ("Library/Caches/com.apple.Safari/cache-2.db", 4),
            ("Library/Caches/com.apple.Safari/cache-3.db", 3), ("Library/Caches/com.spotify.client/data.bin", 10),
            ("Library/Application Support/Slack/IndexedDB.bin", 8), ("Library/Application Support/Slack/logs.txt", 3),
            ("Dokumente/Steuer/2025.pdf", 3), ("Dokumente/Vertrag.pdf", 2),
            ("Dokumente/Fotos alt/IMG_0001.heic", 5), ("Dokumente/Fotos alt/IMG_0002.heic", 5),
            ("Dokumente/Fotos alt/IMG_0003.heic", 5), ("Dokumente/Fotos alt/IMG_0004.heic", 5),
            ("Musik/Album A/01.m4a", 4), ("Musik/Album A/02.m4a", 4), ("Musik/Album A/03.m4a", 4),
            ("Musik/Album A/04.m4a", 4), ("Musik/Album B/01.m4a", 5), ("Musik/Album B/02.m4a", 5),
            ("Musik/Album B/03.m4a", 5),
            ("Projekte/DiskRings/.build/debug.o", 12), ("Projekte/DiskRings/.build/index.db", 6),
            ("Projekte/DiskRings/Sources/main.swift", 1), ("Projekte/WeatherApp/build/app.o", 8),
            ("Filme/Urlaub 2025.mov", 30),
        ]
        for (rel, mb) in files { try write(root, rel, size: mb * MB) }
    }

    /// Veränderungen nach dem ersten Snapshot: +70 MB im neuen Ordner (fünf
    /// gleich große Teile, damit der Ordner selbst und nicht eine einzelne
    /// Datei die Änderung „erklärt“), +12 MB Cache, +15 MB Build, +4 MB
    /// Dokument; −30 MB Film, −15 MB Album B (ganz entfernt), −8 MB durch
    /// eine verkleinerte Datei.
    public static func applyChanges(at root: String) throws {
        for i in 1 ... 5 { try write(root, "\(newFolder)/Xcode.xip.part\(i)", size: 14 * MB) }
        try write(root, "Library/Caches/com.spotify.client/data-2.bin", size: 12 * MB)
        try write(root, "Projekte/DiskRings/.build/release.o", size: 15 * MB)
        try write(root, "Dokumente/Scan 2026.pdf", size: 4 * MB)
        try write(root, "Downloads/foto-export.zip", size: 4 * MB)
        try remove(root, "Filme/Urlaub 2025.mov")
        try remove(root, "Musik/Album B")
    }

    // MARK: Hilfen (nur unterhalb von root)

    static func checkedPath(_ root: String, _ rel: String) throws -> String {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return root + "/" + rel
    }

    static func write(_ root: String, _ rel: String, size: Int) throws {
        let p = try checkedPath(root, rel)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let chunk = [UInt8](repeating: 0x61, count: min(size, 1 << 20))
        var left = size
        while left > 0 {
            let n = min(left, chunk.count)
            let w = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, n) }
            guard w == n else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            left -= n
        }
        // Blöcke sofort zuteilen, damit der folgende Scan die belegte Größe sieht.
        fsync(fd)
    }

    static func remove(_ root: String, _ rel: String) throws {
        try FileManager.default.removeItem(atPath: try checkedPath(root, rel))
    }
}
