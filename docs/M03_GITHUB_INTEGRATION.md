# M03 — GitHub Integration Report

Status: **Complete**, merged in PR #3 · 2026-10-22

## 1. What was built

| Area | Implementation |
|---|---|
| Sign-in | Device flow in the app: Settings › GitHub, or a project's GitHub tab. Shows the code with **Copy Code and Open GitHub**, waits for approval (cancellable), and stores tokens plus account in the Keychain |
| Status and disconnect | Connected as @login (works offline), expired or revoked sign-in prompts a reconnect, **Disconnect** deletes local tokens and offers to open GitHub's *Authorized GitHub Apps* page |
| Repository browsing | Picker over every repository in the Relvora installations, with search, a "Connected" marker, an **Add repositories on GitHub…** link, and reload |
| Project ↔ repositories | New **GitHub** tab per project: connect one or more repositories; disconnect. Stored as `RepositoryConnection` (schema V2) |
| Remote data | Releases (latest, draft, and pre-release flags), tags, and **unreleased changes**: commits since the latest published release with merged pull requests (title, author, labels), plus compare and open-on-GitHub links |
| Fresh vs. cached | Every repository view says whether data is synced, cached (with its age), refreshing, or failed with the reason. Refresh failures keep the cached snapshot |
| Robustness | Typed `GitHubError` with an actionable message for each case. Transient retries, rate-limit handling, a 401 triggers one refresh, offline detection, and same-host pagination with caps |
| Data model | Schema **V2** (adds `RepositoryConnectionEntity`) with a lightweight V1→V2 migration. Backup **format 2** includes connections, and format-1 files still restore |
| Cache | JSON snapshot per repository in `Application Support/Relvora/GitHub Cache/` (ADR 0009) |

Design decisions: [ADR 0009](decisions/0009-github-integration-design.md).

## 2. Verification

| Check | Result |
|---|---|
| `swift test` | **82 tests in 23 suites pass**, 3 runs; 2 opt-in tests skipped by design (live GitHub, fixture generator) |
| New: GitHub (mocked transport) | Device flow (pending, slow_down, denied, disabled, lifetime). Session (no-network reuse, refresh without secret plus saved rotation, **three concurrent calls share one refresh**, bad refresh token signs out, offline failures). API (headers and pinned version, page caps, **foreign pagination host refused**, 401 then refresh then retry, second 401, 5xx retry with backoff, error classification, Retry-After, offline, malformed body, installations dedupe). Sync (full snapshot, no-release fallback, deleted base tag, PR lookup limit with message inference, base-tag choice). Cache (round trip, corrupt and incompatible files ignored). Token redaction |
| New: storage | Real **V1→V2 migration** of the frozen M02 store (`Fixtures/RelvoraV1.store`): every record intact, then a connection added and reopened. Connection lifecycle and rename sync, store-level uniqueness, cascade on project delete, connections in backups |
| Migration on real dev data | The `M02Verification` dev store migrated on first launch: new table present, 9/9 tasks intact, dashboard and sidebar correct |
| Strict lint / app build | **0 findings / 0 warnings**; the built Info.plist carries the client ID and slug |
| CI | **PASS**: PR #3, run 39728089825 on `macos-26` (lint, 82/82 tests, 2 opt-in skipped, app build) |
| Live GitHub in the app | **PASS** with the owner's account. Device-flow sign-in from the app; `erickpea29/Release-Manager` (private) connected and synced. It shows "No releases or tags yet", the latest 8 commits, and **merged PRs #1 and #2** found through the App's permissions |
| Secrets after the live run | **PASS**. The sign-in is a single Keychain item (`com.erickpea29.Relvora.github`). **0** Relvora log entries mention tokens, `Bearer`, or `Authorization`. **No token string** in any file of the app container (preferences, store, cache) |
| Relaunch with a rebuilt binary | **PASS**: still signed in with no Keychain prompt (team signing, ADR 0005/0007); the cached snapshot was shown immediately without a network call |

## 3. Acceptance criteria

| Criterion | Status |
|---|---|
| The user can connect GitHub and browse permitted repositories | **PASS** (live) |
| A project can be associated with one or more repositories | **PASS** (tests + UI) |
| Remote data is clearly distinguished from cached data | **PASS** (status line on every repository view) |
| A failed refresh does not erase cached information | **PASS**: only successful syncs are written (cache tests + model logic) |
| The app never logs tokens or authorization headers | **PASS**: no header or body logging; paths logged as private; redaction tests |
| API errors are displayed as actionable messages | **PASS**: every `GitHubError` has a message plus next step, shown inline |

## 4. Live check (owner)

1. Run the app (Debug), open Relvora › **GitHub** tab, **Connect GitHub…** › **Copy Code and Open GitHub**, then approve.
2. **Connect Repository…** › `erickpea29/Release-Manager`. Unreleased changes and releases load.
3. Turn Wi-Fi off and press **Refresh**: the cached data stays, marked as cached, with "You're offline".

## 5. Findings

- **F17 — An inset can make a fixed-width column flexible.** `.frame(width:)` placed *before* a `.safeAreaInset` whose content had `maxWidth: .infinity` let the repository column grow, splitting the space with the detail view (seen in the live screenshot). Fixed by applying the width after the inset.
- **F18 — Locale-aware times can end in a period** (`11:43 p.m.`). Message templates must not append another; fixed in the sign-in panel.

## 6. Known issues and notes

- No write operations yet (draft releases are M04). The Contents write permission is unused until then.
- When a repository isn't selected in the installation, it doesn't appear in the picker. The picker links to the install page.
- Unreleased PR association is complete only for the newest 40 commits; older ones are inferred and flagged.
- M04 should build the changelog from `RepositorySnapshot.unreleased` rather than calling the API again.
