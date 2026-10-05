// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InstantReplay",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "InstantReplay",
            path: "Sources/InstantReplay"
        )
    ],
    swiftLanguageModes: [.v5]
)
