// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sweep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sweep", targets: ["sweep"]),
        .library(name: "SweepAgent", targets: ["SweepAgent"]),
    ],
    dependencies: [
        // Vendored scan engine. Its package identity keeps the upstream name;
        // see NOTICE for attribution and licence.
        .package(path: "vendor/engine"),
    ],
    targets: [
        .target(
            name: "SweepAgent",
            dependencies: [.product(name: "MacCleanKit", package: "engine")]
        ),
        .executableTarget(
            name: "sweep",
            dependencies: ["SweepAgent"]
        ),
        .testTarget(
            name: "SweepAgentTests",
            dependencies: ["SweepAgent"]
        ),
    ]
)
