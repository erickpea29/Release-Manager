// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RelvoraKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RelvoraCore", targets: ["RelvoraCore"]),
        .library(name: "RelvoraPersistence", targets: ["RelvoraPersistence"]),
    ],
    targets: [
        // Domain types, rules, use cases, and repository protocols. Must not import SwiftData.
        .target(name: "RelvoraCore"),
        // SwiftData implementation of the repository protocols. Its @Model types stay internal.
        .target(name: "RelvoraPersistence", dependencies: ["RelvoraCore"]),
        .testTarget(name: "RelvoraCoreTests", dependencies: ["RelvoraCore"]),
        .testTarget(
            name: "RelvoraPersistenceTests",
            dependencies: ["RelvoraCore", "RelvoraPersistence"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
