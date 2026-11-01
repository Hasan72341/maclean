// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "maclean",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "maclean", targets: ["maclean"]),
        .executable(name: "MacLeanApp", targets: ["MacLeanApp"]),
        .library(name: "MacLeanCore", targets: ["MacLeanCore"]),
    ],
    targets: [
        .target(
            name: "MacLeanCore",
            resources: [.copy("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "maclean", dependencies: ["MacLeanCore"]),
        .executableTarget(name: "MacLeanApp", dependencies: ["MacLeanCore"]),
        .executableTarget(name: "maclean-monitor", dependencies: ["MacLeanCore"]),
        .testTarget(name: "MacLeanCoreTests", dependencies: ["MacLeanCore"]),
    ]
)
