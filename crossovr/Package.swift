// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "crossovr",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "crossovr",
            path: "Sources/crossovr",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
