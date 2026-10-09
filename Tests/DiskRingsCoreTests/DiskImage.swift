import Darwin
import Foundation
import Testing

/// Temporäres Disk-Image (ExFAT, HFS+ …), mit `-nobrowse` eingehängt.
/// Wird mit `detach()` (in Tests immer per `defer`) wieder abgehängt.
final class DiskImage {
    let imagePath: String
    let mountPoint: String
    private(set) var attached = false

    /// Ob `hdiutil` hier benutzbar ist (sonst werden die Tests übersprungen).
    static let isAvailable: Bool = {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/hdiutil")
            && (try? run("/usr/bin/hdiutil", ["info"]))?.status == 0
    }()

    /// Legt ein Image mit dem Dateisystem `fs` in `directory` an und hängt es ein.
    init(fs: String, sizeMB: Int = 64, in directory: String) throws {
        imagePath = directory + "/image.dmg"
        mountPoint = directory + "/mnt"
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        // hdiutil meldet gelegentlich „Resource busy“, wenn parallel andere
        // Images entstehen; dann kurz warten und erneut versuchen.
        try Self.retry("hdiutil create") {
            try Self.run("/usr/bin/hdiutil", [
                "create", "-ov", "-size", "\(sizeMB)m", "-fs", fs, "-volname", "DRTest", "-layout", "NONE", imagePath,
            ])
        }
        try Self.retry("hdiutil attach") {
            try Self.run("/usr/bin/hdiutil", [
                "attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint, imagePath,
            ])
        }
        attached = true
    }

    /// Hängt das Image ab (bei Bedarf erzwungen). Mehrfacher Aufruf ist harmlos.
    func detach() {
        guard attached else { return }
        for args in [["detach", mountPoint], ["detach", "-force", mountPoint]] {
            if (try? Self.run("/usr/bin/hdiutil", args))?.status == 0 {
                attached = false
                return
            }
            usleep(200_000)
        }
    }

    deinit { detach() }

    private static func retry(_ what: String, _ body: () throws -> (status: Int32, output: String)) throws {
        var last = ""
        for attempt in 0 ..< 4 {
            if attempt > 0 { usleep(500_000) }
            let r = try body()
            if r.status == 0 { return }
            last = r.output
        }
        throw FixtureError.failed("\(what): \(last)")
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
