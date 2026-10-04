// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EZLibrary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EZLibrary", targets: ["EZLibraryApp"]),
        .executable(name: "EZLibraryCLI", targets: ["EZLibraryCLI"]),
        .executable(name: "EZLibraryBench", targets: ["EZLibraryBench"]),
        .library(name: "EZLibraryCore", targets: ["EZLibraryCore"])
    ],
    targets: [
        .target(
            name: "EZLibraryCore"
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
                    "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib"
                ])
            ]
        )
    ]
)
