@testable import DiskRingsCore
import Darwin
import Foundation
import Testing

@Suite("App-Umgebung: Sandbox-Erkennung und Folgen")
struct AppEnvironmentTests {
    let sandboxed = AppEnvironment(environment: ["APP_SANDBOX_CONTAINER_ID": "de.stefanrichter.DiskRings"])
    let plain = AppEnvironment(environment: [:])

    @Test("Sandbox wird an APP_SANDBOX_CONTAINER_ID erkannt")
    func detection() {
        #expect(sandboxed.isSandboxed)
        #expect(!plain.isSandboxed)
        #expect(AppEnvironment(isSandboxed: true).isSandboxed)
        // Der Testlauf selbst ist nicht sandboxed.
        #expect(!AppEnvironment.current.isSandboxed)
        // Alte Schnittstelle bleibt gleichbedeutend.
        #expect(DiskutilAPFSListing.isSandboxed(environment: ["APP_SANDBOX_CONTAINER_ID": "x"]))
    }

    @Test("Home-Ordner: in der Sandbox der echte aus der Benutzerdatenbank, nicht der Container")
    func homeDirectory() throws {
        #expect(plain.homeDirectory == NSHomeDirectory())
        let pw = try #require(getpwuid(getuid()))
        let accountHome = String(cString: pw.pointee.pw_dir)
        #expect(sandboxed.homeDirectory == accountHome)
        #expect(!sandboxed.homeDirectory.contains("/Library/Containers/"))
    }

    @Test("Festplattenvollzugriff: in der Sandbox nie „verweigert“ (kein Hinweis, keine Systemeinstellung)")
    func fullDiskAccess() throws {
        let fx = try Fixture()
        try fx.file("readable", size: 10)
        try fx.dir("locked")
        try fx.file("locked/x", size: 10)
        chmod(fx.path("locked/x"), 0)
        defer { chmod(fx.path("locked/x"), 0o644) }
        #expect(FullDiskAccess.status(in: plain, probing: [fx.path("readable")]) == .granted)
        #expect(FullDiskAccess.status(in: plain, probing: [fx.path("locked/x")]) == .denied)
        #expect(FullDiskAccess.status(in: sandboxed, probing: [fx.path("locked/x")]) == .unknown)
        #expect(FullDiskAccess.status(in: sandboxed, probing: [fx.path("readable")]) == .unknown)
        #expect(!FullDiskAccess.shouldWarnBeforeScan(of: "/", status: FullDiskAccess.status(in: sandboxed),
                                                     dismissed: false))
    }

    @Test("diskutil läuft in der Sandbox nicht (Process ist dort verboten)")
    func noDiskutilInSandbox() {
        #expect(DiskutilAPFSListing(environment: sandboxed).volumes(inContainer: "disk3") == nil)
    }

    @Test("Schutzliste nutzt den echten Home-Ordner der Umgebung")
    func protectionHome() {
        let p = ProtectedPaths(environment: sandboxed, appBundlePath: nil, volumeRoots: ["/"])
        #expect(p.home == sandboxed.homeDirectory)
        #expect(p.isProtected(sandboxed.homeDirectory))
        #expect(p.isProtected(sandboxed.homeDirectory + "/Library"))
    }
}
