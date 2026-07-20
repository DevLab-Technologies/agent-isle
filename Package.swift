// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentIsle",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentIsle",
            path: "Sources/AgentIsle",
            exclude: ["Resources/icon_preview.png"],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "AgentIsleTests",
            dependencies: ["AgentIsle"],
            path: "Tests/AgentIsleTests"
        )
    ]
)
