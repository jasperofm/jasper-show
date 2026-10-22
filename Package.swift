// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ReelManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ReelManager", targets: ["ReelManagerApp"]),
        .library(name: "ReelCore", targets: ["ReelCore"]),
    ],
    targets: [
        // Everything that isn't UI: models, SQLite, video pipeline, OAuth, platform clients, posting.
        .target(
            name: "ReelCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI shell.
        .executableTarget(
            name: "ReelManagerApp",
            dependencies: ["ReelCore"]
        ),
        .testTarget(
            name: "ReelCoreTests",
            dependencies: ["ReelCore"]
        ),
    ]
)
