// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stray",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Stray",
            path: "Sources/Stray",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StrayTests",
            dependencies: ["Stray"],
            path: "Tests/StrayTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
