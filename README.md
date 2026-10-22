# Relvora

A native, local-first macOS app for planning software releases: projects, Kanban boards, GitHub release data, changelogs, GitHub draft releases, and an immutable release history.

**Status:** M00–M04 complete; M05 (Design Polish and Distribution) is next. See [docs/PHASE_STATUS.md](docs/PHASE_STATUS.md).

## Requirements

- macOS 26 and Xcode 26.x (validated with Xcode 26.6, Swift 6.3.3)
- No third-party dependencies or tools

## Build and run

```sh
open Relvora.xcodeproj          # then Run (⌘R)
```

Or from Terminal:

```sh
xcodebuild -project Relvora.xcodeproj -scheme Relvora -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Relvora.app
```

### Signing

Without extra setup, builds are ad-hoc signed with bundle ID `com.erickpea29.Relvora.adhoc`, and need no certificate. To sign with your Apple Development identity (recommended for daily use, because Keychain access then survives rebuilds without prompts):

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git-ignored; set DEVELOPMENT_TEAM
```

Team-signed builds use bundle ID `com.erickpea29.Relvora.dev`. The two never share data: a sandboxed app's data container is tied to its signer ([ADR 0007](docs/decisions/0007-build-configuration-and-signing.md)).

### Debug launch options

| Option | Effect |
|---|---|
| `-RelvoraInMemoryStore YES` | Uses a throwaway in-memory store |
| `-RelvoraStoreName <name>` | Uses a separate store file, e.g. for experiments |
| `-RelvoraSeedSampleData YES` | Adds sample projects, tasks, and a release plan if the store is empty |
| `-RelvoraInitialProject <name>` | Opens that project at launch |
| `-RelvoraInitialTab board\|releases\|github` | Opens that project tab |
| `-RelvoraStartGitHubConnect YES` | Starts the GitHub sign-in at launch |
| `-RelvoraConnectRepository owner/name` | Connects that repository to the initial project once signed in |
| `-RelvoraDemoGitHub YES` | Uses an in-memory fake GitHub (`relvora-demo/relvora`) instead of github.com; **Demo GitHub › Publish Drafts** publishes its drafts |
| `-RelvoraDemoScenario <name>` | Steps the first release plan through the workflow: `prepare`, `review`, `draft`, `published`, `mismatch`, `timeout`, `history` |

Example: `open build/DerivedData/Build/Products/Debug/Relvora.app --args -RelvoraStoreName Demo -RelvoraSeedSampleData YES`

Release workflow without a GitHub account: `… --args -RelvoraInMemoryStore YES -RelvoraSeedSampleData YES -RelvoraDemoGitHub YES -RelvoraInitialProject Relvora -RelvoraInitialTab releases -RelvoraConnectRepository relvora-demo/relvora`

## Test and lint

```sh
cd Packages/RelvoraKit && swift test                                         # domain + persistence tests
xcrun swift-format lint --strict --recursive --parallel App Packages         # must be clean (CI enforces)
xcrun swift-format format --in-place --recursive --parallel App Packages    # auto-format
```

CI (`.github/workflows/ci.yml`) runs lint, tests, and an ad-hoc app build on a macOS 26 runner for every pull request and every push to `main`.

## Project layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI app: composition root, navigation, features, design system |
| `Packages/RelvoraKit/` | `RelvoraCore` (domain), `RelvoraPersistence` (SwiftData), `GitHubIntegration` (GitHub auth, API, sync) |
| `Config/` | Build settings, entitlements, local signing template |
| `docs/` | Spec, architecture, data model, design system, phase reports, decisions |
| `spikes/M00/` | Throwaway validation code from M00 |

## Documentation

| Document | Purpose |
|---|---|
| [docs/PHASE_STATUS.md](docs/PHASE_STATUS.md) | Phase checklist and current status |
| [docs/M04_RELEASE_WORKFLOW.md](docs/M04_RELEASE_WORKFLOW.md) | M04 report: release preparation, changelog, drafts, reconciliation, history |
| [docs/M03_GITHUB_INTEGRATION.md](docs/M03_GITHUB_INTEGRATION.md) | M03 report: GitHub sign-in, repositories, sync, cache |
| [docs/M02_PROJECTS_AND_KANBAN.md](docs/M02_PROJECTS_AND_KANBAN.md) | M02 report: projects, Kanban, release plans, backup |
| [docs/BACKUP_AND_RESTORE.md](docs/BACKUP_AND_RESTORE.md) | How to back up, restore, and recover |
| [docs/M01_FOUNDATION.md](docs/M01_FOUNDATION.md) | M01 report: what was built and verified |
| [docs/M00_TECHNICAL_VALIDATION.md](docs/M00_TECHNICAL_VALIDATION.md) | M00 evidence and findings |
| [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md) | MVP scope and open product questions |
| [docs/TECHNICAL_ARCHITECTURE.md](docs/TECHNICAL_ARCHITECTURE.md) | Modules, boundaries, concurrency, security |
| [docs/DATA_MODEL.md](docs/DATA_MODEL.md) | Entities, state machines, migrations |
| [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md) | Appearance, materials, accessibility |
| [docs/GITHUB_APP_SETUP.md](docs/GITHUB_APP_SETUP.md) | Registering the GitHub App |
| [docs/decisions/](docs/decisions/) | Architecture decision records |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Original plan (written under the working name "Release Manager") |
