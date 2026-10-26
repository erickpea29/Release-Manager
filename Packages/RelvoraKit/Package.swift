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
        .library(name: "RelvoraMCP", targets: ["RelvoraMCP"]),
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
        // Claude's connection: an MCP server on 127.0.0.1 that reads projects and creates tasks (ADR 0018).
        .target(name: "RelvoraMCP", dependencies: ["RelvoraCore"]),
        .testTarget(name: "RelvoraCoreTests", dependencies: ["RelvoraCore"]),
        .testTarget(name: "GitHubIntegrationTests", dependencies: ["GitHubIntegration", "RelvoraCore"]),
        .testTarget(name: "RelvoraUpdatesTests", dependencies: ["RelvoraUpdates", "RelvoraCore"]),
        .testTarget(name: "RelvoraMCPTests", dependencies: ["RelvoraMCP", "RelvoraCore", "RelvoraPersistence"]),
        .testTarget(
            name: "RelvoraPersistenceTests",
            dependencies: ["RelvoraCore", "RelvoraPersistence"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
