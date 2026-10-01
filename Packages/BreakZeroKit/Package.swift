// swift-tools-version: 6.0
import PackageDescription

// One local package, three library products (see ARCHITECTURE.md §2).
// Core must stay Foundation-only so `swift test` runs on Linux.
let package = Package(
    name: "BreakZeroKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "LiteWeb", targets: ["LiteWeb"]),
        .library(name: "Shielding", targets: ["Shielding"]),
    ],
    targets: [
        .target(
            name: "Core",
            resources: [.copy("Resources/Recipes")]
        ),
        .target(
            name: "LiteWeb",
            dependencies: ["Core"],
            resources: [.copy("Resources/Scripts")]
        ),
        .target(
            name: "Shielding",
            dependencies: ["Core"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "LiteWebTests", dependencies: ["LiteWeb"]),
        .testTarget(name: "ShieldingTests", dependencies: ["Shielding"]),
    ],
    swiftLanguageModes: [.v6]
)
