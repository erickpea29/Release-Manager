# Technical Architecture

Status: implemented through M05. Decisions are recorded in [decisions/](decisions/).

## 1. Layout

```text
release-manager/                        # repository: erickpea29/Release-Manager
├── Relvora.xcodeproj                   # app target, synchronized folders (ADR 0004)
├── App/                                # SwiftUI app target
│   ├── RelvoraApp.swift, AppModel.swift  # scenes, composition root, launch options
│   ├── Navigation/                     # RootView (split view), SidebarView
│   ├── Features/                       # Dashboard, Projects, Board, Releases, GitHub, History, Settings
│   ├── DesignSystem/                   # tokens, panel style, window material
│   └── Debug/                          # sample data, demo GitHub (Debug builds only)
├── Packages/RelvoraKit/                # local Swift package
│   ├── Sources/RelvoraCore/            # domain, pure planners/rules, services, repository protocols, backup format
│   ├── Sources/RelvoraPersistence/     # SwiftData schema + repository implementation
│   ├── Sources/GitHubIntegration/      # GitHub auth, REST client, sync, cache, release remote
│   ├── Sources/RelvoraUpdates/         # updates of Relvora itself: signatures, installer, XPC protocol (ADR 0017)
│   ├── Sources/RelvoraMCP/             # Claude's connection: MCP over HTTP on 127.0.0.1, task tools (ADR 0018)
│   └── Tests/                          # swift test
├── Updater/                            # RelvoraUpdater.xpc: the updater service, outside the sandbox (ADR 0017)
├── UITests/                            # XCUITest target RelvoraUITests (in-memory store, demo GitHub)
├── scripts/release/                    # build-release.sh: archive, sign, notarize, staple (ADR 0011)
├── Config/                             # Shared.xcconfig, Relvora.entitlements, Local.xcconfig (git-ignored)
├── spikes/M00/                         # throwaway validation code
├── docs/
└── .github/workflows/                  # ci.yml (lint, tests, build, UI tests), release.yml (notarized builds)
```

`GitHubIntegration` (M03) holds GitHub auth, the REST client, sync, and the snapshot cache ([ADR 0009](decisions/0009-github-integration-design.md)). Module boundaries are added only when they pay for themselves: persistence is its own target so the compiler keeps `@Model` types out of the app and core.

## 2. Dependency rules

```text
App (SwiftUI views, @Observable AppModel)
  ├─▶ RelvoraCore                              (no UI, no SwiftData, no networking)
  ├─▶ RelvoraPersistence ─▶ RelvoraCore        (SwiftData; @Model types internal)
  ├─▶ GitHubIntegration  ─▶ RelvoraCore        (M03; DTOs internal)
  ├─▶ RelvoraUpdates     ─▶ RelvoraCore        (Security framework; also linked by RelvoraUpdater.xpc)
  └─▶ RelvoraMCP         ─▶ RelvoraCore        (Network.framework; the tools use RelvoraCore services)
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
- Release workflow writes (plan status plus one snapshot operation) go through one guarded `record` transaction that compares the plan's stored status first; snapshots are write-once ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)).
- Backup: versioned JSON (`BackupDocument`, format 4 including settings), independent of the schema. Restore validates the whole document, writes a safety copy, then replaces everything in one transaction ([guide](BACKUP_AND_RESTORE.md)).

## 5. GitHub integration

| Concern | Approach |
|---|---|
| Auth | Device flow, client ID only, refresh without secret ([ADR 0002](decisions/0002-github-app-device-flow-no-backend.md)) |
| Transport | `HTTPTransport` protocol. Production uses an ephemeral `URLSession` with `urlCache = nil`; tests use a mock |
| Headers | `Accept: application/vnd.github+json`, pinned `X-GitHub-Api-Version: 2022-11-28` (ADR 0009) |
| Pagination | `Link` header `rel="next"` |
| Errors | 401 → re-auth. 403 → rate-limited (`remaining=0` or `retry-after`) or forbidden (show `x-accepted-github-permissions`). 404 → missing or no access. 409 → conflict. 422 → validation. 429 → rate-limited. 5xx → transient |
| Retries | Reads retry twice on 5xx, timeouts, and dropped connections. **`POST /releases` is sent once** (only a 401 or short `Retry-After`, which GitHub rejects before acting, is repeated). An unknown outcome is reconciled by listing releases and matching tag + target commit, because GitHub accepts duplicate drafts (M00 F13; ADR 0010) |
| Release workflow | `ReleaseWorkflow` (RelvoraCore) owns every release state change and talks to GitHub through the `ReleaseRemote` protocol, implemented by `GitHubReleaseRemote`. Intent is saved before the create request; publication is reported only after the tag resolves to the reviewed SHA |
| Rate limits | 5,000/h per user, shared with the user's other tools. Make requests serially, use conditional requests (`ETag`, where 304 responses are free), and wait at least 1 s between writes |
| Cache | Cached releases and tags stored with `fetchedAt`. Refresh replaces them only on success. The UI shows fresh vs. cached and the last sync time |
| Automatic refresh | The repository open in the GitHub tab refreshes on the interval in Settings (default 5 minutes) while Relvora is active, and on opening or returning to the app when its data is older. `RefreshSchedule` waits a full interval after a failure and pauses until a rate limit resets. One refresh costs up to about 50 requests |
| Identity | Stable numeric IDs (`repository.id`, `release.id`); names are display only |

## 6. Security and privacy

- Tokens live only in Keychain ([ADR 0005](decisions/0005-credential-storage.md)), wrapped in a redacting `Secret` type. No credentials appear in SwiftData, `UserDefaults`, logs, or crash reports.
- Logging uses `os.Logger`, with any GitHub payload fields marked `.private`. The `Authorization` header is never logged.
- App Sandbox entitlements: `network.client`, `network.server` (Claude's connection on 127.0.0.1), and `files.user-selected.read-write` (for export and backup). Hardened Runtime is on.
- Claude's MCP server is off by default. It listens on 127.0.0.1 only, refuses other `Host` headers (DNS rebinding) and any `Origin` (web pages), and requires an access key kept in the Keychain. Its tools read projects and create tasks, nothing else ([ADR 0018](decisions/0018-claude-creates-tasks.md)).
- The updater service (`RelvoraUpdater.xpc`) is the one part outside the sandbox, because it replaces the app. Only its app can connect to it. It checks every update itself (Developer ID, same team, notarized) before swapping it in ([ADR 0017](decisions/0017-update-relvora-from-relvora.md)).
- Redirects never carry the `Authorization` header to another host (GitHub serves release files from its file storage), and never leave HTTPS.
- No analytics. No third-party dependencies.

## 7. Testing and CI

- `swift test` covers core and integration logic with mocks; no real GitHub account is involved.
- `xcodebuild test` runs the **RelvoraUITests** target (XCUITest). Each test launches the app with:
  - an in-memory store with sample data;
  - the in-memory **demo GitHub**, a fake of the REST endpoints that drives the real API client, sync, and workflow;
  - a throwaway settings suite (`-RelvoraDefaultsSuite`).
  Tests therefore never touch real data, settings, or GitHub.
- Notifications: wording, timing, and "announce once" are pure (`AppNotifications`). Debug builds with a throwaway settings suite record notifications instead of showing them ([ADR 0019](decisions/0019-notifications.md)).
- The UI tests cover navigation and quick actions, board editing by keyboard, the release flow (draft, publishing on GitHub or from Relvora, history), reconciliation after a timeout, project groups, offline states, settings, updates (an offered version, refused by the updater service), Claude's connection (tasks created over MCP appear on the open Board), notifications (recorded), and an accessibility audit.
- Live GitHub tests are opt-in only (environment variable), never run in CI.
- CI runs on GitHub Actions with the `macos-26` image:
  - one job runs lint, `swift test`, and an ad-hoc app build;
  - a parallel job runs the UI tests, after allowing UI automation with `automationmodetool`.
- The **Release** workflow builds notarized Developer ID apps ([ADR 0011](decisions/0011-distribution-developer-id.md), [DISTRIBUTION.md](DISTRIBUTION.md)).

## 8. Signing and builds

- The committed configuration uses ad-hoc signing.
- Developers put `DEVELOPMENT_TEAM` and their identity in `Config/Local.xcconfig`.
- One identity per bundle ID on a given Mac (M00 F5). Without `Local.xcconfig`, local builds must use a distinct bundle-ID suffix so they never share a sandbox container with team-signed builds.
- Release builds use `com.erickpea29.Relvora` (no suffix), signed with Developer ID and notarized by `scripts/release/build-release.sh` in GitHub Actions. Credentials exist only as Actions secrets ([ADR 0011](decisions/0011-distribution-developer-id.md)).
