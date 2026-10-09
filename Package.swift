// swift-tools-version:6.0
import Foundation
import PackageDescription

// Mit den Command Line Tools (ohne Xcode) findet der Compiler das Makro-Plugin
// von Swift Testing nicht von selbst (siehe docs/DECISIONS.md). Der Pfad wird
// nur gesetzt, wenn er existiert; mit Xcode ist der Zusatz wirkungslos.
let testingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: testingPluginPath)
        ? [.unsafeFlags(["-plugin-path", testingPluginPath])]
        : []

let package = Package(
    name: "DiskRings",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskRingsCore", targets: ["DiskRingsCore"]),
        .executable(name: "DiskRings", targets: ["DiskRings"]),
        .executable(name: "diskrings-cli", targets: ["diskrings-cli"]),
    ],
    targets: [
        .target(name: "DiskRingsCore"),
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
