// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RelvoraKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RelvoraCore", targets: ["RelvoraCore"]),
        .library(name: "RelvoraPersistence", targets: ["RelvoraPersistence"]),
        .library(name: "GitHubIntegration", targets: ["GitHubIntegration"]),
        .library(name: "RelvoraUpdates", targets: ["RelvoraUpdates"]),
    ],
    targets: [
        // Domain types, rules, use cases, and repository protocols. Must not import SwiftData.
        .target(name: "RelvoraCore"),
        // SwiftData implementation of the repository protocols. Its @Model types stay internal.
        .target(name: "RelvoraPersistence", dependencies: ["RelvoraCore"]),
        // GitHub App auth, REST client, sync, and cache. DTOs stay internal; results are RelvoraCore values.
        .target(name: "GitHubIntegration", dependencies: ["RelvoraCore"]),
        // Checks and installs updates of Relvora itself: code signatures, the zip, the atomic swap (ADR 0017). The
        // app and its updater service both link it.
        .target(name: "RelvoraUpdates", dependencies: ["RelvoraCore"]),
        .testTarget(name: "RelvoraCoreTests", dependencies: ["RelvoraCore"]),
        .testTarget(name: "GitHubIntegrationTests", dependencies: ["GitHubIntegration", "RelvoraCore"]),
        .testTarget(name: "RelvoraUpdatesTests", dependencies: ["RelvoraUpdates", "RelvoraCore"]),
        .testTarget(
            name: "RelvoraPersistenceTests",
            dependencies: ["RelvoraCore", "RelvoraPersistence"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
