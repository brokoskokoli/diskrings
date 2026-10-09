@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

/// Temporärer Fixture-Baum. Alles wird unterhalb eines eigenen Ordners im
/// temporären Verzeichnis angelegt und mit `remove()` wieder gelöscht.
final class Fixture {
    /// Aufgelöster Pfad (ohne Symlinks wie /var → /private/var).
    let root: String

    init(_ label: String = #function) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskRingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let r = realpath(base.path, nil) else { throw FixtureError.failed("realpath") }
        root = String(cString: r)
        free(r)
    }

    func path(_ rel: String) -> String { rel.isEmpty ? root : root + "/" + rel }

    @discardableResult
    func dir(_ rel: String) throws -> String {
        let p = path(rel)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Legt eine Datei mit `size` Byte Inhalt an (Zwischenordner automatisch).
    @discardableResult
    func file(_ rel: String, size: Int = 0, byte: UInt8 = 0x61) throws -> String {
        let p = path(rel)
        let parent = (p as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FixtureError.errno("open \(p)", errno) }
        defer { close(fd) }
        if size > 0 {
            let chunk = [UInt8](repeating: byte, count: min(size, 1 << 20))
            var left = size
            while left > 0 {
                let n = min(left, chunk.count)
                let w = chunk.withUnsafeBytes { write(fd, $0.baseAddress, n) }
                guard w == n else { throw FixtureError.errno("write", errno) }
                left -= n
            }
        }
        return p
    }

    /// Datei mit rohen Namens-Bytes (z. B. NFD), ohne Normalisierung durch Foundation.
    func rawFile(dir rel: String, nameBytes: [UInt8], size: Int) throws {
        let dirPath = try dir(rel)
        var full = Array(dirPath.utf8)
        full.append(UInt8(ascii: "/"))
        full += nameBytes
        full.append(0)
        let fd = full.withUnsafeBufferPointer { buf in
            buf.withMemoryRebound(to: CChar.self) { open($0.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        }
        guard fd >= 0 else { throw FixtureError.errno("open raw", errno) }
        let data = [UInt8](repeating: 0x62, count: size)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, size) }
        close(fd)
    }

    func hardlink(_ existing: String, _ newRel: String) throws {
        let p = path(newRel)
        try FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard link(existing.hasPrefix("/") ? existing : path(existing), p) == 0 else {
            throw FixtureError.errno("link", errno)
        }
    }

    func symlink(_ rel: String, to target: String) throws {
        let p = path(rel)
        try FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard Darwin.symlink(target, p) == 0 else { throw FixtureError.errno("symlink", errno) }
    }

    /// Sparse-Datei: logische Größe `logical`, nur am Anfang und Ende ein Byte.
    func sparseFile(_ rel: String, logical: Int) throws -> String {
        let p = try file(rel, size: 0)
        let fd = open(p, O_WRONLY)
        guard fd >= 0 else { throw FixtureError.errno("open sparse", errno) }
        defer { close(fd) }
        var one: UInt8 = 1
        _ = pwrite(fd, &one, 1, 0)
        _ = pwrite(fd, &one, 1, off_t(logical - 1))
        return p
    }

    /// Ordnerkette mit `depth` Ebenen (über `mkdirat`, damit auch Pfade über
    /// PATH_MAX gehen). Gibt die Komponentennamen zurück.
    func deepChain(_ rel: String, depth: Int, component: String = "d", leafFileSize: Int) throws {
        var fd = open(try dir(rel), O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw FixtureError.errno("open deep", errno) }
        for _ in 0 ..< depth {
            guard mkdirat(fd, component, 0o755) == 0 else { throw FixtureError.errno("mkdirat", errno) }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY)
            close(fd)
            guard next >= 0 else { throw FixtureError.errno("openat", errno) }
            fd = next
        }
        let f = openat(fd, "blatt.bin", O_WRONLY | O_CREAT, 0o644)
        let data = [UInt8](repeating: 0x63, count: leafFileSize)
        _ = data.withUnsafeBytes { write(f, $0.baseAddress, leafFileSize) }
        close(f)
        close(fd)
    }

    /// Belegte Größe laut `lstat` (st_blocks * 512).
    static func allocated(_ path: String) -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }

    /// Summe der belegten Größe aller Einträge laut `lstat`, Hardlinks einmal.
    func expectedAllocatedTotal() -> UInt64 {
        var seen = Set<[UInt64]>()
        var total: UInt64 = 0
        let paths = (FileManager.default.subpaths(atPath: root) ?? []).map { root + "/" + $0 }
        for p in paths {
            var st = stat()
            guard lstat(p, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR { continue }
            if st.st_nlink > 1, !seen.insert([UInt64(st.st_dev), st.st_ino]).inserted { continue }
            total += UInt64(st.st_blocks) * 512
        }
        return total
    }

    /// Löscht den Fixture-Baum. Nur innerhalb des temporären Verzeichnisses.
    func remove() {
        precondition(root.contains("/DiskRingsTests-"), "Löschen nur in Test-Verzeichnissen")
        // Rechte zurücksetzen, falls ein Test chmod 000 gesetzt hat.
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwx", root]
        chmod.standardError = FileHandle.nullDevice
        try? chmod.run()
        chmod.waitUntilExit()
        // rm (fts) kommt auch mit Pfaden über PATH_MAX zurecht.
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", root]
        try? rm.run()
        rm.waitUntilExit()
    }

    deinit { remove() }
}

enum FixtureError: Error {
    case failed(String)
    case errno(String, Int32)
}

/// `du -sk <path>` in Byte (Kibibyte × 1024).
func duBytes(_ path: String, extraArgs: [String] = []) throws -> UInt64 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-sk"] + extraArgs + [path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard let kb = UInt64(text.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") else {
        throw FixtureError.failed("du-Ausgabe: \(text)")
    }
    return kb * 1024
}

/// Prüft die Invarianten aus SPEC 4.2 für den ganzen Baum (`ScanTree.validate()`).
func expectValidTree(_ tree: ScanTree, sourceLocation: SourceLocation = #_sourceLocation) {
    let problems = tree.validate()
    #expect(problems.isEmpty, "Invarianten verletzt: \(problems)", sourceLocation: sourceLocation)
}

/// Sequenzieller Standard-Scan für Tests.
func scan(_ path: String, _ configure: (inout ScanOptions) -> Void = { _ in }) throws -> ScanResult {
    var o = ScanOptions()
    configure(&o)
    return try ScanEngine(options: o).scanBlocking(path)
}
