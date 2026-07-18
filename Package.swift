// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "EZLibrary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EZLibrary", targets: ["SeratoToolsApp"]),
        .executable(name: "SeratoToolsCLI", targets: ["SeratoToolsCLI"]),
        .library(name: "SeratoToolsCore", targets: ["SeratoToolsCore"])
    ],
    targets: [
        .target(
            name: "SeratoToolsCore"
        ),
        .executableTarget(
            name: "SeratoToolsCLI",
            dependencies: ["SeratoToolsCore"]
        ),
        .executableTarget(
            name: "SeratoToolsApp",
            dependencies: ["SeratoToolsCore"]
        ),
        .testTarget(
            name: "SeratoToolsCoreTests",
            dependencies: ["SeratoToolsCore"],
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
