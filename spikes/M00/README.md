# M00 spikes (throwaway)

Validation code for [M00](../../docs/M00_TECHNICAL_VALIDATION.md). It is not the product's architecture and will not be extended. M01 creates the real project.

| Path | Validates |
|---|---|
| `SpikeKit/Sources/PersistenceSpike` | SwiftData behind a repository protocol, `ModelActor` under Swift 6, versioned schema migration |
| `SpikeKit/Sources/CredentialSpike` | Keychain wrapper (file-based and data-protection keychains) |
| `SpikeKit/Sources/GitHubAuthSpike` | Device-flow client, REST probe, error classification, secret redaction |
| `SpikeKit/Sources/gh-auth-spike` | Live GitHub App validation CLI |
| `M00SpikeApp/` | Sandboxed `.app`: persistence across relaunch, Keychain under real signing, window materials |

## Unit tests

```sh
cd spikes/M00/SpikeKit && swift test
```

## Spike app

```sh
cd spikes/M00/M00SpikeApp
# Team-signed build (manual signing, no provisioning profile). Replace TEAM_ID / identity with your own.
xcodebuild -project M00Spike.xcodeproj -scheme M00Spike -derivedDataPath /tmp/m00dd \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.erickpea29.ReleaseManager.M00Spike.teamsigned build
BIN=/tmp/m00dd/Build/Products/Debug/M00Spike.app/Contents/MacOS/M00Spike
$BIN --env; $BIN --seed "Alpha"; $BIN --dump; $BIN --keychain
```

> Do not run builds with different signing identities under the same bundle ID. macOS blocks launch on a
> container-ownership consent dialog (see the M00 report).

Visual check of window materials: opens all six material/appearance combinations, one at a time (quit each with ⌘Q):

```sh
DEVELOPMENT_TEAM=TEAM_ID spikes/M00/visual-check.sh
```

## Live GitHub validation

Requires a registered GitHub App ([setup](../../docs/GITHUB_APP_SETUP.md)). Only the public client ID is used.

```sh
cd spikes/M00/SpikeKit
GITHUB_APP_CLIENT_ID=Iv23li... swift run gh-auth-spike validate --repo owner/name          # read-only
GITHUB_APP_CLIENT_ID=Iv23li... swift run gh-auth-spike validate --repo owner/name --write  # also creates+deletes a draft
swift run gh-auth-spike probe --repo owner/name [--write]                                # reuses the saved token
swift run gh-auth-spike forget
```

Run `probe` with the same build as `validate`. A rebuilt binary has a new ad-hoc signature, and reading the saved keychain item would prompt.

The CLI never prints tokens. It reports status codes, GitHub's `x-accepted-github-permissions` header, rate limits, and counts.
