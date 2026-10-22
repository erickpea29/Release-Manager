# 0004 — Project structure and tooling

- **Status:** Accepted (validated in M00)
- **Date:** 2026-10-19

## Context

The plan suggests an `.xcodeproj` plus Swift packages, with no JavaScript tooling. No project generator (XcodeGen, Tuist) is installed, and the plan prefers no unnecessary dependencies.

## Decision

- One app target in a hand-maintained `Relvora.xcodeproj` using **synchronized folder groups** (`objectVersion = 77`). New files need no project edits, which keeps the project file small and reviewable.
- Core code lives in a **local Swift package** at `Packages/RelvoraKit/` with library products `RelvoraCore` (domain, no SwiftData) and `RelvoraPersistence` (SwiftData), referenced via `XCLocalSwiftPackageReference`. `GitHubIntegration` is added in M03.
  - This avoids a root-level `Package.swift` next to the `.xcodeproj`, which makes Xcode open the package instead of the project.
- Core logic is testable with `swift test` without building the app. App/UI tests use `xcodebuild test`.
- Signing settings that identify a person (team ID) go in a git-ignored `Config/Local.xcconfig`; the committed default is ad-hoc signing.
- Formatting uses `swift-format` bundled with Xcode (`xcrun swift-format`), so no extra install.

## Consequences

- The `.pbxproj` is edited through Xcode or by hand, with no regeneration step.
- CI needs only Xcode on a macOS runner.

## Evidence

`spikes/M00/M00SpikeApp/M00Spike.xcodeproj` (hand-written, synchronized folders, local package) builds with `xcodebuild` under ad-hoc and Apple Development signing.
