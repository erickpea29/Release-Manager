# M01 — Foundation Report

Status: **Complete** (pending owner merge of PR #1) · 2026-10-21

## 1. What was built

| Area | Implementation |
|---|---|
| Project | `Relvora.xcodeproj` (hand-maintained, synchronized `App/` folder) + local package `Packages/RelvoraKit` |
| Modules | `RelvoraCore`: domain, rules, use cases, repository protocols, typed errors; no SwiftData. `RelvoraPersistence`: SwiftData schema and repositories, with `@Model` types internal |
| Domain | `Project`, `BoardColumn`, `ProjectTask` (+ `ChecklistItem`, `TaskPriority`, `TaskType`), `ReleasePlan` (+ `ReleasePlanStatus`), `ReleaseVersion`/`SemanticVersion` (SemVer 2.0 precedence + custom labels), `FractionalIndex` ordering |
| Persistence | `RelvoraSchemaV1` with versioned migration plan; relationships with cascade/nullify rules; one `ModelActor` serving all repositories; every method is a single all-or-nothing transaction with rollback; integrity rules (task ↔ column ↔ plan ↔ project) |
| Errors | `ValidationError` and `PersistenceError` (typed throws at the repository boundary). User-facing message + recovery suggestion; technical detail only in `os.Logger` with `.private` |
| Dependency injection | `AppEnvironment` (store + use cases) built once in `AppModel`. Debug launch options for in-memory, named, and seeded stores |
| Navigation | `Window` scene, `NavigationSplitView`: Dashboard, Release History, Projects. Per-window selection (`@SceneStorage`); sidebar visibility stored explicitly (M00 F11); ⇧⌘N New Project; Settings scene |
| Design system | Spacing/radius tokens, opaque `panel()` surface, appearance (system/light/dark), window material (opaque / AppKit translucent, forced opaque with Reduce Transparency or Increase Contrast) |
| Features (minimal) | Create a project (validated, default 5-column board); dashboard cards; project page shows its board columns; store-failure recovery screen. Full project and Kanban management is M02 |
| Conventions | `.swift-format` (4-space indent, 120 columns), strict lint enforced in CI; `Config/Shared.xcconfig` + git-ignored `Local.xcconfig` ([ADR 0007](decisions/0007-build-configuration-and-signing.md)) |
| CI | `.github/workflows/ci.yml` on `macos-26`: lint → `swift test` → ad-hoc app build |

## 2. Verification

| Check | Command | Result |
|---|---|---|
| Package tests | `cd Packages/RelvoraKit && swift test` | **22 tests in 6 suites pass**; 4 consecutive runs, no flakes |
| Lint | `xcrun swift-format lint --strict --recursive --parallel App Packages` | **0 findings** |
| App build, team-signed | `xcodebuild … build` with `Local.xcconfig` | **Succeeded, 0 warnings**; `com.erickpea29.Relvora.dev`, sandbox + network-client + user-selected-files entitlements |
| App build, fresh clone (ad-hoc) | same, `Local.xcconfig` moved away | **Succeeded**; "Sign to Run Locally", `com.erickpea29.Relvora.adhoc` |
| Save and restore in the real app | Launch 1 `-RelvoraStoreName M01Verification -RelvoraSeedSampleData YES`, quit; launch 2 without seeding | **3 projects restored** after relaunch; screenshots in light and dark |
| CI on GitHub | PR #1, run 39722910284 | **PASS** in 54 s on `macos-26` (macOS 26.6.2, Xcode 26.6, Swift 6.3.3): lint, 22/22 tests, app build |

Test coverage highlights:
- SemVer precedence, using the specification's own example chain.
- Malformed versions.
- Fractional-index exhaustion and renormalization.
- Label normalization and name validation.
- Create-project use case with a fake repository.
- Store restart survival, archiving, checklist sync, and cross-project integrity, with a rollback check.
- Cascade delete with row counts, release-plan round trip, and not-found errors.

## 3. Acceptance criteria

| Criterion | Status |
|---|---|
| The application launches successfully | **PASS** (sandboxed, both signing modes) |
| Project data can be saved and restored | **PASS** (unit tests on disk + real-app relaunch) |
| Core logic can be tested independently of the UI | **PASS** (`swift test`, no app build needed) |
| CI builds the application and runs tests | **PASS** (run 39722910284) |
| No credentials or personal data are committed | **PASS** (team ID only in git-ignored `Local.xcconfig`; scanned before commit) |

## 4. Known issues and notes

- No UI tests yet. The plan schedules UI-test expansion for M05, and M02 adds the first ones once there are interactions to test. Running them locally needs Xcode's automation permission.
- No app icon yet (M05).
- Dashboard cards and the project page are intentionally minimal; editing, archiving, search, Kanban, and backup are M02.
- macOS CI minutes on a private repository count 10× against the free allowance. The workflow cancels superseded runs and runs only on PRs, pushes to `main`, and manual dispatch.
- Schema V1 is frozen once merged; the next schema change must add V2 with a migration stage and the first fixture store.

## 5. Next (M02)

Project editing, archiving, and search; release-plan editing with the one-active-plan rule; configurable columns; drag-and-drop Kanban with persistent order; task editor (priority, type, labels, notes, checklist); filters; backup/export/restore.
