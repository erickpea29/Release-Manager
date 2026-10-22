# Product Specification

Derived from [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), which takes precedence. This document restates the MVP precisely and records gaps that need a decision (§6).

## 1. Product

A native macOS app for one developer managing several software projects: plan releases, track work on a Kanban board, pull release data from GitHub, prepare changelogs, create **draft** GitHub releases, and keep an immutable history of what shipped.

- **Single user, single Mac.** No accounts, sync, or backend.
- **Local-first.** Everything except GitHub features works offline.
- **GitHub is an integration,** not the source of truth for local planning.

## 2. MVP capabilities

| Area | Capabilities |
|---|---|
| Projects | Create, edit, archive, search. Show current version, next planned version, progress, connected repositories, recent release activity |
| Release plans | Version string (semver, prerelease, or custom), optional title and description, planned date, target branch and commit. **One active plan per project** |
| Kanban | Per-project configurable columns (defaults: Backlog, To Do, In Progress, Review, Done), drag-and-drop with persistent order, one completion column |
| Tasks | Title, notes (Markdown), priority, type (feature, improvement, bug fix, documentation, maintenance, other), labels, basic checklist, optional release plan |
| GitHub | Connect/disconnect, list repositories where the app is installed, associate one or more with a project, browse releases/tags/commits/merged PRs, show sync time and cached vs. fresh state, open items in the browser |
| Changelog | Deterministic generation from commits and PRs between the previous tag and the target commit, grouped by category/label; edit; export Markdown; flag missing data |
| Release | Validate tag and target SHA, confirm, create a **GitHub draft**, open it on GitHub, detect publication, store an immutable snapshot |
| History | Browse snapshots with links to GitHub |
| Appearance | System/light/dark, accent color, optional translucent window with opaque fallback |
| Data | Local export, backup, and restore |

## 3. Release lifecycle (user-visible states)

`Planned` → `Draft created` → `Published` (verified on GitHub). `Needs reconciliation` is entered whenever a remote outcome is unknown, and is left only after re-reading GitHub. A plan can be `Cancelled` from Planned or Draft created. State rules live in [DATA_MODEL.md §3](DATA_MODEL.md#3-state-machines).

## 4. Non-negotiable safety rules

1. Never publish a release from the app (MVP). Drafts only; publication happens on GitHub.
2. Never move, overwrite, or delete a tag.
3. Show the exact target commit SHA, tag, and notes, and require confirmation before creating a draft.
4. After a timeout or ambiguous failure on create, read GitHub before any retry.
5. Never report "Published" until GitHub confirms it.
6. Never auto-complete tasks on release. Warn about incomplete tasks; allow an explicit override.
7. Snapshot content never changes after creation.
8. A failed refresh never deletes cached data. User-entered changelog text survives remote failures.

## 5. Non-goals (MVP)

Team features, accounts, sync, hosted backend, deployment, auto-publishing, AI, App Store Connect, non-macOS platforms, time tracking, estimation, task dependencies.

## 6. Open questions and plan gaps

Each item has a proposed default, used unless the owner decides otherwise.

| # | Gap or contradiction | Proposed default |
|---|---|---|
| G1 | **Minimum macOS** not specified | **Decided: macOS 26** ([ADR 0003](decisions/0003-minimum-macos-target.md)) |
| G2 | **Snapshot timing vs. immutability.** §6 step 13 creates the snapshot after publication, but the plan also says to preserve notes "even if the GitHub draft is later edited", and the snapshot has a changing `releaseState` | Create the snapshot **at draft creation**, freezing tasks, notes, tag, and SHA as reviewed. Only lifecycle fields may change, once each, through allowed transitions (`publishedAt`, URL, published notes if they differ). Content fields are write-once |
| G3 | **ReleasePlan has no repository link,** but a release targets one repository | Add `repositoryConnectionID`; one repository per release plan in the MVP |
| G4 | `Task.statusID` refers to a board column | Rename to `columnID` |
| G5 | "Browse repositories accessible to the authorized user". A GitHub App user token only sees repositories where the app is **installed** | UI lists installed repositories, with an "Add repositories on GitHub…" link to the install page |
| G6 | "Disconnection revokes credentials". Revocation needs the client secret | Delete local tokens; link to GitHub's *Authorized GitHub Apps* page to revoke |
| G7 | **A draft does not create its tag** (verified in M00), and GitHub accepts duplicate drafts for one tag. The same tag could also be created elsewhere between draft and publication | Before creating a draft, check for an existing tag *and* for existing releases or drafts with that `tag_name`. On reconciliation, verify the published tag resolves to the reviewed SHA. If not, mark the plan `Needs reconciliation` and warn |
| G8 | Merged-PR retrieval has no single REST endpoint, and API `2026-03-10` drops `merge_commit_sha` | Per-commit `GET /commits/{sha}/pulls` with a request budget, plus PR-number parsing from merge/squash commit messages as a fallback. Choose the API version in M03 |
| G9 | Target commits changing `.github/workflows/*` need the Workflows permission | Excluded; show an actionable error |
| G10 | Final bundle ID, app name, GitHub App name, license | Spike uses `com.erickpea29.ReleaseManager`; owner to confirm |
| G11 | Distribution: no Developer ID certificate | Decide in M05 (notarized Developer ID vs. local builds only) |
| G12 | Preferences storage location | `UserDefaults` behind a `PreferencesStore` protocol, included in backups |
| G13 | Backup scope | Local entities and preferences as versioned JSON. Excludes credentials and the re-fetchable GitHub cache |
