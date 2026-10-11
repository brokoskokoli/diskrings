// swift-tools-version:6.1
import Foundation
import PackageDescription

// Mit den Command Line Tools (ohne Xcode) findet der Compiler das Makro-Plugin
// von Swift Testing nicht von selbst (siehe dev/DECISIONS.md). Der Pfad wird
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

// Automatische Updates (Sparkle) nur in der GitHub-Variante (Developer ID).
// Die Mac-App-Store-Variante baut mit `--disable-default-traits`: Dann ist
// Sparkle weder gelinkt noch eingebettet, und der Code unter `#if Updates`
// fehlt (siehe dev/DECISIONS.md, „Automatische Updates mit Sparkle“).
// Sparkle exakt gepinnt: 2.10.0 (13.09.2026, Commit eef1a539a373c1f1a320624b1130fc5de7b2e100;
// Binärziel mit SHA-256 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
// im Manifest von Sparkle, Revision in Package.resolved).
let package = Package(
    name: "DiskRings",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskRingsCore", targets: ["DiskRingsCore"]),
        .executable(name: "DiskRings", targets: ["DiskRings"]),
        .executable(name: "diskrings-cli", targets: ["diskrings-cli"]),
    ],
    traits: [
        .trait(name: "Updates", description: "Automatische Updates per Sparkle (nur GitHub-Variante)"),
        .default(enabledTraits: ["Updates"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "DiskRingsCore", resources: [.process("Resources")]),
        .executableTarget(
            name: "DiskRings",
            dependencies: [
                "DiskRingsCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["Updates"])),
            ]
        ),
        .executableTarget(name: "diskrings-cli", dependencies: ["DiskRingsCore"]),
        .testTarget(
            name: "DiskRingsCoreTests",
            dependencies: ["DiskRingsCore"],
            swiftSettings: testSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
