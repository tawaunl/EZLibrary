// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SeratoTools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SeratoTools", targets: ["SeratoToolsApp"]),
        .library(name: "SeratoToolsCore", targets: ["SeratoToolsCore"])
    ],
    targets: [
        .target(
            name: "SeratoToolsCore"
        ),
        .executableTarget(
            name: "SeratoToolsApp",
            dependencies: ["SeratoToolsCore"]
        ),
        .testTarget(
            name: "SeratoToolsCoreTests",
            dependencies: ["SeratoToolsCore"],
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
