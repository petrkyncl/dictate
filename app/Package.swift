// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dictate",
            path: "Sources/Dictate",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
