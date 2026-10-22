# Technical Architecture

Status: implemented through M01. Decisions are recorded in [decisions/](decisions/).

## 1. Layout

```text
release-manager/                        # repository: erickpea29/Release-Manager
├── Relvora.xcodeproj                   # app target, synchronized folders (ADR 0004)
├── App/                                # SwiftUI app target
│   ├── RelvoraApp.swift, AppModel.swift  # scenes, composition root, launch options
│   ├── Navigation/                     # RootView (split view), SidebarView
│   ├── Features/                       # Dashboard, Projects, History, Settings
│   ├── DesignSystem/                   # tokens, panel style, window material
│   └── Debug/                          # sample data (Debug builds only)
├── Packages/RelvoraKit/                # local Swift package
│   ├── Sources/RelvoraCore/            # domain, pure planners/rules, services, repository protocols, backup format
│   ├── Sources/RelvoraPersistence/     # SwiftData schema + repository implementation
│   └── Tests/                          # swift test
├── Config/                             # Shared.xcconfig, Relvora.entitlements, Local.xcconfig (git-ignored)
├── spikes/M00/                         # throwaway validation code
├── docs/
└── .github/workflows/ci.yml
```

`GitHubIntegration` joins the package in M03. Module boundaries are added only when they pay for themselves: persistence is its own target so the compiler keeps `@Model` types out of the app and core.

## 2. Dependency rules

```text
App (SwiftUI views, @Observable AppModel)
  ├─▶ RelvoraCore                              (no UI, no SwiftData, no networking)
  ├─▶ RelvoraPersistence ─▶ RelvoraCore        (SwiftData; @Model types internal)
  └─▶ GitHubIntegration  ─▶ RelvoraCore        (M03; DTOs internal)
```

- Views never touch `URLSession`, SwiftData, or Keychain. They call `AppModel` (and later feature models), which calls use cases and repositories held by a single `AppEnvironment` built at launch.
- Launch options (Debug builds only): `-RelvoraInMemoryStore YES`, `-RelvoraStoreName <name>` (separate store file), `-RelvoraSeedSampleData YES` (seeds an empty store). Used for UI checks and future UI tests.
- If the store cannot open, the app shows a recovery screen instead of crashing.
- GitHub DTOs never leave `GitHubIntegration`; they are mapped to domain values.
- SwiftData `@Model` types never leave the persistence implementation ([ADR 0001](decisions/0001-swiftdata-behind-repositories.md)).

## 3. Concurrency

- Swift 6 language mode everywhere. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the packages use the default (nonisolated).
- Repositories are actors (`ModelActor`) returning `Sendable` structs. Services are `Sendable` structs or actors.
- Token refresh is serialized in one actor, because refresh tokens rotate and concurrent refreshes would invalidate each other.
- Network calls support task cancellation. UI models cancel stale loads when the selection changes.

## 4. Persistence

- SwiftData, with an on-disk store in the sandbox container's Application Support directory.
- Every repository call uses a fresh `ModelContext`; failed writes are discarded, never rolled back in place ([ADR 0008](decisions/0008-fresh-context-per-operation.md)).
- Board edits are computed by the pure `BoardPlanner` as `BoardChanges` and applied in one transaction. The store re-checks invariants (task ↔ column ↔ project, exactly one completion column, empty-before-delete), even for changes that bypass the planner.
- A `VersionedSchema` and migration plan from the first release; migration tests use committed fixture stores.
- Multi-record operations run in one `ModelContext` save, which is one transaction.
- Backup: versioned JSON (`BackupDocument`, format 1), independent of the schema. Restore validates the whole document, writes a safety copy, then replaces everything in one transaction ([guide](BACKUP_AND_RESTORE.md)).

## 5. GitHub integration

| Concern | Approach |
|---|---|
| Auth | Device flow, client ID only, refresh without secret ([ADR 0002](decisions/0002-github-app-device-flow-no-backend.md)) |
| Transport | `HTTPTransport` protocol. Production uses an ephemeral `URLSession` with `urlCache = nil`; tests use a mock |
| Headers | `Accept: application/vnd.github+json`, pinned `X-GitHub-Api-Version` (decide `2022-11-28` vs `2026-03-10` in M03) |
| Pagination | `Link` header `rel="next"` |
| Errors | 401 → re-auth. 403 → rate-limited (`remaining=0` or `retry-after`) or forbidden (show `x-accepted-github-permissions`). 404 → missing or no access. 409 → conflict. 422 → validation. 429 → rate-limited. 5xx → transient |
| Retries | Bounded exponential backoff for idempotent GETs and 5xx/429 only. **Never blind-retry `POST /releases`**: after a timeout, list releases and look for the tag before retrying. GitHub accepts duplicate drafts, so it will not reject a repeat (M00 F13) |
| Rate limits | 5,000/h per user, shared with the user's other tools. Make requests serially, use conditional requests (`ETag`, where 304 responses are free), and wait at least 1 s between writes |
| Cache | Cached releases and tags stored with `fetchedAt`. Refresh replaces them only on success. The UI shows fresh vs. cached and the last sync time |
| Identity | Stable numeric IDs (`repository.id`, `release.id`); names are display only |

## 6. Security and privacy

- Tokens live only in Keychain ([ADR 0005](decisions/0005-credential-storage.md)), wrapped in a redacting `Secret` type. No credentials appear in SwiftData, `UserDefaults`, logs, or crash reports.
- Logging uses `os.Logger`, with any GitHub payload fields marked `.private`. The `Authorization` header is never logged.
- App Sandbox entitlements: `network.client` and `files.user-selected.read-write` (for export and backup). Hardened Runtime is on.
- No analytics. No third-party dependencies.

## 7. Testing and CI

- `swift test` covers core and integration logic with mocks; no real GitHub account is involved.
- `xcodebuild test` covers UI tests through a mocked `AppEnvironment` (launch argument).
- Live GitHub tests are opt-in only (environment variable), never run in CI.
- CI: GitHub Actions on a macOS runner with an Xcode 26 image, running `swift test`, then `xcodebuild build test` with ad-hoc signing.

## 8. Signing and builds

- The committed configuration uses ad-hoc signing.
- Developers put `DEVELOPMENT_TEAM` and their identity in `Config/Local.xcconfig`.
- One identity per bundle ID on a given Mac (M00 F5). Without `Local.xcconfig`, local builds must use a distinct bundle-ID suffix so they never share a sandbox container with team-signed builds.
