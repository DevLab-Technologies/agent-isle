// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeIsland",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeIsland",
            path: "Sources/ClaudeIsland",
            exclude: ["Resources/icon_preview.png"],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        )
    ]
)
