# Technical Architecture

Status: proposed for M01, based on M00 evidence. Decisions are recorded in [decisions/](decisions/).

## 1. Layout

```text
release-manager/
├── ReleaseManager.xcodeproj          # app + UI-test targets, synchronized folders (ADR 0004)
├── App/                              # SwiftUI app target: App/, Features/, DesignSystem/, Resources/
├── Packages/ReleaseManagerKit/       # local Swift package
│   ├── Sources/ReleaseManagerCore/   # domain models, use cases, repository protocols, SwiftData impl
│   ├── Sources/GitHubIntegration/    # auth, REST client, DTOs, release workflow services
│   └── Tests/…                       # swift test
├── Config/                           # Shared.xcconfig (committed), Local.xcconfig (git-ignored)
├── docs/
└── .github/workflows/ci.yml
```

Persistence stays inside `ReleaseManagerCore` until there is a reason to split it out. Module boundaries are added only when they pay for themselves.

## 2. Dependency rules

```text
App (SwiftUI views, @Observable feature models)
  ├─▶ ReleaseManagerCore    (no UI, no networking)
  └─▶ GitHubIntegration ─▶ ReleaseManagerCore (domain types only)
```

- Views never touch `URLSession`, SwiftData, or Keychain. They call feature models, which call use cases and services injected through a single `AppEnvironment` container.
- GitHub DTOs never leave `GitHubIntegration`; they are mapped to domain values.
- SwiftData `@Model` types never leave the persistence implementation ([ADR 0001](decisions/0001-swiftdata-behind-repositories.md)).

## 3. Concurrency

- Swift 6 language mode everywhere. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; the packages use the default (nonisolated).
- Repositories are actors (`ModelActor`) returning `Sendable` structs. Services are `Sendable` structs or actors.
- Token refresh is serialized in one actor, because refresh tokens rotate and concurrent refreshes would invalidate each other.
- Network calls support task cancellation. UI models cancel stale loads when the selection changes.

## 4. Persistence

- SwiftData, with an on-disk store in the sandbox container's Application Support directory.
- A `VersionedSchema` and migration plan from the first release; migration tests use committed fixture stores.
- Multi-record operations run in one `ModelContext` save, which is one transaction.
- Backup: versioned JSON envelope (`formatVersion`, `exportedAt`, entities). Restore validates fully before replacing anything.

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
