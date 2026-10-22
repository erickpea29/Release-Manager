# 0011 — Distribution: notarized Developer ID builds from GitHub Actions

- **Status:** Accepted (M05; the owner chose Developer ID)
- **Date:** 2026-10-22

## Context

Gap G11 asked how Relvora is distributed: notarized Developer ID builds, or local builds only. The owner chose **notarized Developer ID**. This Mac has Apple Development certificates only. There is no backend, and secrets must never enter the repository (ADR 0002, ADR 0007).

## Decisions

1. **Developer ID and notarization.**
   - Release builds are signed with a Developer ID Application certificate, using the hardened runtime (already on) and a secure timestamp.
   - They are notarized with `notarytool` and an App Store Connect API key, then stapled.
   - Entitlements are unchanged: App Sandbox, outgoing network, and user-selected files.
2. **Built by GitHub Actions, triggered by publishing a GitHub release.**
   - This fits Relvora's own workflow: you prepare and draft the release in Relvora, then publish it on GitHub.
   - The workflow then attaches `Relvora-<version>.zip` and its SHA-256 checksum to that release.
   - A manual run (`workflow_dispatch`) builds any version as an artifact.
3. **Secrets live only in GitHub Actions.**
   - The certificate (`.p12`) and the notary key (`.p8`) are imported into a temporary keychain or file during the job, then deleted.
   - The Team ID is also a secret, keeping the rule that it is never committed.
4. **Graceful without secrets.**
   - Without secrets, the same job builds an ad-hoc signed test package.
   - That package is uploaded as an artifact and never attached to a release.
   - Pull requests that change the pipeline get this dry run, so the pipeline is tested before any credentials exist.
5. **One script, local or CI.** `scripts/release/build-release.sh` performs every step and verification, so problems can be reproduced locally.
6. **Versioning.**
   - `CFBundleShortVersionString` is the tag's numeric version; a prerelease suffix appears only in the file name.
   - `CFBundleVersion` is the workflow run number.
   - The bundle ID is `com.erickpea29.Relvora`, with no suffix.

## Consequences

- Users get an app that opens without Gatekeeper warnings. It has no automatic updates: updates are downloaded from Releases (Sparkle is a possible later step).
- The release build has its own data container and Keychain identity. Moving from a development build is done with a backup and a new GitHub sign-in.
- Distribution depends on the owner's Apple Developer Program membership and on renewing the certificate every five years.
- Assets of a private repository are visible only to its collaborators; public distribution needs a public repository or another download location.
- macOS runners cost more on private repositories; the release job runs only on release, on a manual run, or on pipeline changes.

## Evidence

- The ad-hoc path of the script was run locally. It produced a universal (arm64 and x86_64) app, `com.erickpea29.Relvora` 0.0.0, with the hardened runtime and sandbox entitlements, no demo code, and the public client ID.
- The dry run on the M05 pull request ran on CI.
- The signed and notarized path needs the owner's secrets ([DISTRIBUTION.md](../DISTRIBUTION.md) §1).
