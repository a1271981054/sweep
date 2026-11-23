// swift-tools-version: 6.0
// Trimmed vendored manifest: sweep only builds the MacCleanKit engine target.
// The remaining upstream targets, tests and tooling were removed; see NOTICE.md.
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCleanKit", targets: ["MacCleanKit"]),
    ],
    targets: [
        .target(
            name: "MacCleanKit",
            dependencies: [],
            path: "Sources/MacCleanKit"
        ),
    ]
)
