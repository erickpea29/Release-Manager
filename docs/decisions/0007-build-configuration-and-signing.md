# 0007 — Build configuration and signing

- **Status:** Accepted (M01)
- **Date:** 2026-10-21

## Context

M00 found two constraints:
- A sandboxed app's data container is bound to the signer that created it. Launching a build with a different signer under the same bundle ID blocks on a consent dialog (F5).
- Team signing is needed for prompt-free Keychain access across rebuilds (ADR 0005), but team IDs must not be committed, and CI has no certificates.

## Decision

- Signing and bundle-ID settings live in `Config/Shared.xcconfig`, the app target's base configuration. The `.pbxproj` sets none of them.
  - Default: ad-hoc (`CODE_SIGN_IDENTITY = -`), bundle ID `com.erickpea29.Relvora.adhoc`.
- `Shared.xcconfig` optionally includes the git-ignored `Config/Local.xcconfig` (`#include?`). A template is committed as `Local.xcconfig.example`. It sets `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY = Apple Development`, and the bundle suffix `.dev`.
- The release distribution build (M05) will use the bare `com.erickpea29.Relvora` with Developer ID signing.
- Each signing style therefore has its own bundle ID and its own data container, so they can never collide.

## Consequences

- Fresh clones and CI build with no setup and no secrets.
- Data created by a `.dev` build is not visible to an `.adhoc` build, and vice versa. This is intentional.
- Moving to the release bundle ID in M05 needs a one-time data import or backup/restore (backup/restore arrives in M02).
