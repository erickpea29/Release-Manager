// swift-tools-version: 6.2
// M00 technical-validation spike. Throwaway code: not the production package layout (see docs/decisions).

import PackageDescription

let package = Package(
    name: "SpikeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PersistenceSpike", targets: ["PersistenceSpike"]),
        .library(name: "CredentialSpike", targets: ["CredentialSpike"]),
        .library(name: "GitHubAuthSpike", targets: ["GitHubAuthSpike"]),
        .executable(name: "gh-auth-spike", targets: ["gh-auth-spike"]),
    ],
    targets: [
        .target(name: "PersistenceSpike"),
        .target(name: "CredentialSpike"),
        .target(name: "GitHubAuthSpike"),
        .executableTarget(name: "gh-auth-spike", dependencies: ["GitHubAuthSpike", "CredentialSpike"]),
        .testTarget(name: "PersistenceSpikeTests", dependencies: ["PersistenceSpike"]),
        .testTarget(name: "GitHubAuthSpikeTests", dependencies: ["GitHubAuthSpike"]),
    ]
)
