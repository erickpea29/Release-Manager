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
| Projects | Create, edit, archive, search. Show current version, next planned version, progress, connected repositories, recent release activity. Group projects, for example by company, in collapsible sidebar sections ([ADR 0014](decisions/0014-project-groups.md)) |
| Release plans | Version string (semver, prerelease, or custom), optional title and description, planned date, target branch and commit. **One active plan per project**. The next version is suggested from the changes since the last release ([ADR 0016](decisions/0016-version-suggestion-and-release-checklist.md)) |
| Backlog | Every unfinished task outside the version being planned, listed below that version's tasks (like a sprint above its backlog). Tasks move between them with a button, drag and drop, or the context menu ([ADR 0012](decisions/0012-backlog-tab-and-version-board.md)) |
| Kanban (Board) | The tasks of the version being planned. Per-project configurable columns (defaults: To Do, In Progress, Review, Done; “Backlog” is reserved for the tab), drag-and-drop with persistent order, one completion column |
| Tasks | Title, notes (Markdown), priority, type (feature, improvement, bug fix, documentation, maintenance, other), labels, basic checklist, optional release plan |
| GitHub | Connect/disconnect, list repositories where the app is installed, associate one or more with a project, browse releases/tags/commits/merged PRs, show sync time and cached vs. fresh state, refresh the open repository automatically (every 5 minutes by default, Settings › GitHub), open items in the browser |
| Pull requests and CI | Open pull requests with their CI and whether they can merge, in the release plan and the GitHub tab; **merge from Relvora** after a confirmation, only once CI passed; the latest commit whose CI passed offered as the release's commit ([ADR 0020](decisions/0020-pull-requests-and-ci.md)) |
| Changelog | Deterministic generation from commits and PRs between the previous tag and the target commit, grouped by category/label; edit; export Markdown; flag missing data |
| Release | A per-project **release checklist** whose steps must all be ticked before the draft. Validate tag and target SHA, confirm, create a **GitHub draft**, open it on GitHub, **publish it from Relvora** after a second confirmation (or on GitHub), verify publication, store an immutable snapshot |
| History | Browse snapshots with links to GitHub |
| Appearance | System/light/dark, accent color, optional translucent window with opaque fallback |
| Data | Local export, backup, and restore |
| Claude | Claude Code sessions on the Mac read projects and the version being planned, and add tasks to it or to the Backlog, through an MCP server in Relvora that is off until turned on in Settings › Claude ([ADR 0018](decisions/0018-claude-creates-tasks.md)) |
| Notifications | macOS notifications when a release is published (drafts waiting on GitHub are checked every 5 minutes), a version is planned for today, a new Relvora is available, Claude added tasks, or CI finished on a pull request or on the release's branch ([ADR 0020](decisions/0020-pull-requests-and-ci.md)). Each kind can be turned off ([ADR 0019](decisions/0019-notifications.md)) |
| Updates | Relvora finds its new versions in its own repository's releases, and installs one when the user chooses: a backup first, then checksum and signature checks (Developer ID, same team, notarized), then it relaunches ([ADR 0017](decisions/0017-update-relvora-from-relvora.md)) |

## 3. Release lifecycle (user-visible states)

`Planned` → `Draft created` → `Published` (verified on GitHub). `Needs reconciliation` is entered whenever a remote outcome is unknown (including while the create request is in flight) or the published release differs from what was reviewed, and is left only after re-reading GitHub. A plan can be `Cancelled` from Planned; a drafted plan returns to Planned when its draft is deleted on GitHub (M04, [ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)). State rules live in [DATA_MODEL.md §3](DATA_MODEL.md#3-state-machines).

## 4. Non-negotiable safety rules

1. A release is always a GitHub draft first. It is published only after the user confirms the draft as GitHub has it, in Relvora or on GitHub; never automatically ([ADR 0015](decisions/0015-publish-from-relvora.md), which replaced "drafts only" in 0.1.1).
2. Never move, overwrite, or delete a tag.
3. Show the exact target commit SHA, tag, and notes, and require confirmation before creating a draft.
4. After a timeout or ambiguous failure on create, read GitHub before any retry.
5. Never report "Published" until GitHub confirms it.
6. Never auto-complete tasks on release. Warn about incomplete tasks; allow an explicit override.
7. Snapshot content never changes after creation.
8. A failed refresh never deletes cached data. User-entered changelog text survives remote failures.

## 5. Non-goals (MVP)

Team features, accounts, sync, hosted backend, deployment, auto-publishing, AI inside Relvora (Claude Code can connect from outside: [ADR 0018](decisions/0018-claude-creates-tasks.md)), App Store Connect, non-macOS platforms, time tracking, estimation, task dependencies.

## 6. Open questions and plan gaps

Each item has a proposed default, used unless the owner decides otherwise.

| # | Gap or contradiction | Proposed default |
|---|---|---|
| G1 | **Minimum macOS** not specified | **Decided: macOS 26** ([ADR 0003](decisions/0003-minimum-macos-target.md)) |
| G2 | **Snapshot timing vs. immutability.** §6 step 13 creates the snapshot after publication, but the plan also says to preserve notes "even if the GitHub draft is later edited", and the snapshot has a changing `releaseState` | **Decided (M04):** the snapshot is created **when the draft is requested** (as `pending`, before the request), freezing tasks, notes, tag, and SHA as reviewed. Only lifecycle fields change, once each (`publishedAt`, URL, published notes if they differ) ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)) |
| G3 | **ReleasePlan has no repository link,** but a release targets one repository | **Decided (M04):** `repositoryConnectionID` (schema V3); one repository per release plan |
| G4 | `Task.statusID` refers to a board column | Rename to `columnID` |
| G5 | "Browse repositories accessible to the authorized user". A GitHub App user token only sees repositories where the app is **installed** | UI lists installed repositories, with an "Add repositories on GitHub…" link to the install page |
| G6 | "Disconnection revokes credentials". Revocation needs the client secret | Delete local tokens; link to GitHub's *Authorized GitHub Apps* page to revoke |
| G7 | **A draft does not create its tag** (verified in M00), and GitHub accepts duplicate drafts for one tag. The same tag could also be created elsewhere between draft and publication | **Implemented (M04):** before creating a draft, check the tag *and* releases or drafts with that `tag_name`; the create is sent once; on reconciliation, verify the published tag resolves to the reviewed SHA, else `Needs reconciliation` with both values shown ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md)) |
| G8 | Merged-PR retrieval has no single REST endpoint, and API `2026-03-10` drops `merge_commit_sha` | Per-commit `GET /commits/{sha}/pulls` with a request budget, plus PR-number parsing from merge/squash commit messages as a fallback. Choose the API version in M03 |
| G9 | Target commits changing `.github/workflows/*` need the Workflows permission | Excluded; show an actionable error |
| G10 | Final bundle ID, app name, GitHub App name, license | **Decided:** product, app, and GitHub App are named **Relvora**; bundle ID `com.erickpea29.Relvora` (with `.dev`/`.adhoc` suffixes for local builds). License still open |
| G11 | Distribution: no Developer ID certificate | **Decided (M05): notarized Developer ID**, built by GitHub Actions when a release is published ([ADR 0011](decisions/0011-distribution-developer-id.md)); the owner adds the certificate and notary key as secrets ([DISTRIBUTION.md](DISTRIBUTION.md)) |
| G12 | Preferences storage location | **Implemented (M05):** `UserDefaults` through one app `Preferences` store; included in backups (format 4) |
| G13 | Backup scope | Local entities and preferences as versioned JSON. Excludes credentials and the re-fetchable GitHub cache |
