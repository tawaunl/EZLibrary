// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EZLibrary",
    // Only `EZLibrarySnapshotKit` builds for iOS today: it is deliberately
    // free of Serato binary-format and filesystem-layout knowledge. The app,
    // CLI, and `EZLibraryCore` remain macOS-only.
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "EZLibrary", targets: ["EZLibraryApp"]),
        .executable(name: "EZLibraryCLI", targets: ["EZLibraryCLI"]),
        .executable(name: "EZLibraryBench", targets: ["EZLibraryBench"]),
        .library(name: "EZLibraryCore", targets: ["EZLibraryCore"]),
        .library(name: "EZLibrarySnapshotKit", targets: ["EZLibrarySnapshotKit"])
    ],
    targets: [
        // The portable snapshot format. Pure Foundation and free of any
        // Serato binary-format or filesystem-layout knowledge, so it builds
        // for iOS — that is the point of it being its own target rather than
        // conditionally-compiled corners of EZLibraryCore.
        .target(
            name: "EZLibrarySnapshotKit"
        ),
        .target(
            name: "EZLibraryCore",
            dependencies: ["EZLibrarySnapshotKit"]
        ),
        .executableTarget(
            name: "EZLibraryCLI",
            dependencies: ["EZLibraryCore"]
        ),
        .executableTarget(
            name: "EZLibraryBench",
            dependencies: ["EZLibraryCore"]
        ),
        .executableTarget(
            name: "EZLibraryApp",
            dependencies: ["EZLibraryCore"]
        ),
        .testTarget(
            name: "EZLibraryCoreTests",
            dependencies: ["EZLibraryCore"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                // swift-testing's framework isn't on the default search path
                // when only Command Line Tools (no full Xcode) are installed.
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
