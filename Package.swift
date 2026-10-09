// swift-tools-version:6.0
import Foundation
import PackageDescription

// Mit den Command Line Tools (ohne Xcode) findet der Compiler das Makro-Plugin
// von Swift Testing nicht von selbst (siehe docs/DECISIONS.md). Der Pfad wird
// nur gesetzt, wenn er existiert und die Command Line Tools die aktive
// Toolchain sind. Auf Rechnern mit Xcode (z. B. GitHub-Runnern, die zusätzlich
// die CLT installiert haben) bleibt er weg, damit Xcodes Compiler nicht das
// Plugin einer anderen Swift-Version lädt.
let cltRoot = "/Library/Developer/CommandLineTools"
let testingPluginPath = cltRoot + "/usr/lib/swift/host/plugins/testing"
let usesCommandLineTools: Bool = {
    // SwiftPM setzt SDKROOT beim Auswerten des Manifests auf das SDK der aktiven Toolchain.
    if let sdk = ProcessInfo.processInfo.environment["SDKROOT"] { return sdk.hasPrefix(cltRoot) }
    if let dev = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return dev.hasPrefix(cltRoot) }
    let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
    return selected?.hasPrefix(cltRoot) ?? true
}()
let testSwiftSettings: [SwiftSetting] =
    usesCommandLineTools && FileManager.default.fileExists(atPath: testingPluginPath)
        ? [.unsafeFlags(["-plugin-path", testingPluginPath])]
        : []

let package = Package(
    name: "DiskRings",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskRingsCore", targets: ["DiskRingsCore"]),
        .executable(name: "DiskRings", targets: ["DiskRings"]),
        .executable(name: "diskrings-cli", targets: ["diskrings-cli"]),
    ],
    targets: [
        .target(name: "DiskRingsCore", resources: [.process("Resources")]),
        .executableTarget(name: "DiskRings", dependencies: ["DiskRingsCore"]),
        .executableTarget(name: "diskrings-cli", dependencies: ["DiskRingsCore"]),
        .testTarget(
            name: "DiskRingsCoreTests",
            dependencies: ["DiskRingsCore"],
            swiftSettings: testSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
