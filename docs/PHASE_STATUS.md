# Phase Status

| Phase | Status |
|---|---|
| M00 — Technical Validation | **Complete** (2026-10-21) |
| M01 — Foundation | **Complete**: merged in PR #1 ([report](M01_FOUNDATION.md)) |
| M02 — Projects and Kanban | **Complete**: merged in PR #2 ([report](M02_PROJECTS_AND_KANBAN.md)) |
| M03 — GitHub Integration | **Complete**: merged in PR #3 ([report](M03_GITHUB_INTEGRATION.md)) |
| M04 — Release Workflow and History | **Complete**: merged in PR #5, fix in PR #6 ([report](M04_RELEASE_WORKFLOW.md)) |
| M05 — Design Polish and Distribution | **Complete**: merged in PR #8 ([report](M05_DESIGN_POLISH_AND_DISTRIBUTION.md)) |
| First-release polish | **Complete**: merged in PR #9 ([report](FIRST_RELEASE_POLISH.md)) |
| 0.1.1 — Project groups, publishing from Relvora | **Complete**: merged in PR #10, released as v0.1.1 ([ADR 0014](decisions/0014-project-groups.md), [ADR 0015](decisions/0015-publish-from-relvora.md)) |
| 0.1.2 — Version suggestion, release checklist | **Complete**: merged in PR #11, released as v0.1.2 ([ADR 0016](decisions/0016-version-suggestion-and-release-checklist.md)) |
| 0.2.0 — Updating Relvora from Relvora | **Complete**: merged in PR #12, released as v0.2.0 ([ADR 0017](decisions/0017-update-relvora-from-relvora.md)) |
| 0.2.1 — Claude creates tasks | **Complete**: merged in PR #13, released as v0.2.1, the first version installed by Relvora's updater ([ADR 0018](decisions/0018-claude-creates-tasks.md)) |
| Next release (0.2.2) — Notifications | **In progress** on branch `feature/notifications` ([ADR 0019](decisions/0019-notifications.md)) |

The feature ideas are in [ROADMAP.md](ROADMAP.md).

## M00 checklist

- [x] Inspect environment, Xcode, SDKs ([report §1](M00_TECHNICAL_VALIDATION.md#1-development-environment))
- [x] Choose minimum macOS target: **macOS 26** ([ADR 0003](decisions/0003-minimum-macos-target.md))
- [x] Minimal SwiftUI app with local persistence, restored after relaunch
- [x] SwiftData migration strategy validated on disk (lightweight + custom stages)
- [x] Token storage validated in a sandboxed, signed app (file-based keychain)
- [x] GitHub auth flow, permissions, refresh, and revocation researched in official docs
- [x] GitHub App registered; live device flow and secretless refresh PASS ([report §2.5](M00_TECHNICAL_VALIDATION.md#25-github-app-authorization-pass))
- [x] Repository probe with granted access: all endpoints 200 with exactly 3 permissions
- [x] Draft-release semantics: a draft does not create its tag; duplicate drafts are accepted (F13)
- [x] Translucency prototype (three modes plus Reduce Transparency fallback), verified programmatically
- [x] Visual readability check of translucency ([report §2.4](M00_TECHNICAL_VALIDATION.md#24-window-translucency-pass-visual-check-2026-10-21))
- [x] Architecture changes documented (ADRs 0001–0006, spec documents)
- [x] Unresolved risks documented ([report §4](M00_TECHNICAL_VALIDATION.md#4-open-risks-and-decisions-needed-before-m01))

## M01 checklist

- [x] Xcode project and minimal package boundaries (`Relvora.xcodeproj`, `RelvoraCore`, `RelvoraPersistence`)
- [x] Conventions: swift-format config + strict lint, xcconfig-based build settings, local signing template
- [x] Domain models and persistence repositories
- [x] Schema V1 with versioned migration plan and freeze rule
- [x] Navigation shell and design-system foundations
- [x] Typed errors and dependency injection (`AppEnvironment`)
- [x] GitHub Actions CI building and testing on macOS 26 (first run passed in 54 s)
- [x] Initial unit tests (22) and documentation

## M02 checklist

- [x] Project creation, editing, archiving, deletion, and search
- [x] Release-plan creation, editing, cancel, delete (one active plan per project)
- [x] Configurable Kanban columns (add, rename, reorder, completion column, delete with task move)
- [x] Drag-and-drop with persistent ordering (plus menu-based moves)
- [x] Task editing: priority, type, labels, notes, checklist, release
- [x] Filters and empty states
- [x] Backup export and restore (validated, safety copy, atomic)
- [x] Data-integrity tests for moves, edits, deletions
- [x] CI on PR #2 (lint, 49/49 tests, app build)
- [ ] Owner manual interaction checklist ([report §5](M02_PROJECTS_AND_KANBAN.md#5-not-verified-automatically-manual-checklist-for-the-owner)) — not reported; owner merged PR #2

## M03 checklist

- [x] GitHub authorization (device flow) and Keychain storage
- [x] Connection status and disconnection
- [x] Repository browsing and search (installation repositories)
- [x] Associate repositories with projects (schema V2 + migration, backup format 2)
- [x] Fetch releases, tags, commits, merged pull requests
- [x] Pagination and rate-limit handling
- [x] Cache with sync timestamps (fresh vs. cached shown)
- [x] Expired credentials, permission errors, offline, transient failures
- [x] Mock-based tests + opt-in live test
- [x] CI on PR #3
- [x] Live check in the app with the owner's GitHub account (sign-in, repository, commits, merged PRs, no token leaks)

## M04 checklist

- [x] Release preparation and validation (local and GitHub checks)
- [x] Target repository, branch, commit (full SHA), and tag
- [x] Changelog from tasks, commits, and merged pull requests; editing; Markdown export
- [x] Existing tags and conflicting releases or drafts detected before any write
- [x] GitHub draft creation after confirmation (draft only; incomplete tasks need explicit confirmation)
- [x] Ambiguous outcomes reconciled by reading GitHub before any retry ([ADR 0010](decisions/0010-release-workflow-and-reconciliation.md))
- [x] Publication detected and verified (tag → reviewed SHA)
- [x] Immutable release snapshots (schema V3, V2 fixture and migration)
- [x] Release history with links to GitHub
- [x] Tests: duplicate requests, failed saves, conflicting tags, external publication (127 tests)
- [x] Live read-only check with the owner's repository (no draft created)
- [x] CI on PR #5 (lint, 127/127 tests, 2 opt-in skipped, app build)
- [x] Live draft creation on the owner's repository, with approval (release 420378956, tag `v0.0.0-relvora-test`)
- [x] Owner published the draft on GitHub; the app verified the publication (tag at `05157e7`) ([report §2](M04_RELEASE_WORKFLOW.md#2-verification))

## M05 checklist

- [x] Views finished: dashboard (needs attention, recent releases), board (keyboard), releases, history, settings (General, Board, Releases, GitHub)
- [x] Light, dark, and system appearance
- [x] Configurable accent color and translucent window, with an opaque fallback
- [x] Keyboard navigation (board, Task and Go menus) and accessibility labels; Xcode accessibility audit in UI tests
- [x] Quick actions (⌘K)
- [x] UI tests (12) and error-state tests (offline, timeout), plus 3 new package tests
- [x] Installation, backups, recovery, and GitHub authorization documented ([INSTALLATION.md](INSTALLATION.md))
- [x] Signing and notarization instructions ([DISTRIBUTION.md](DISTRIBUTION.md))
- [x] Release build automation (notarized Developer ID, [ADR 0011](decisions/0011-distribution-developer-id.md))
- [x] macOS versions: minimum 26.0 (deployment target), tested on 26.6.2 locally and on the CI image (26.6.2 25G83)
- [x] CI on PR #8 (lint, 130 package tests, build, 12 UI tests; Release dry run)
- [x] Owner: Developer ID certificate, notary key, and GitHub secrets ([DISTRIBUTION.md §1](DISTRIBUTION.md#1-one-time-setup-owner)); signed, notarized, and stapled build verified 2026-10-22

## First-release polish checklist

- [x] Collapsed sidebar as an icon strip, one component with the full sidebar ([ADR 0013](decisions/0013-custom-sidebar-container.md))
- [x] Backlog tab; the Board shows the version being planned ([ADR 0012](decisions/0012-backlog-tab-and-version-board.md))
- [x] Automatic GitHub refresh (Settings › GitHub)
- [x] Fixes: Release History centering, centered release details, accessibility labels and contrast
- [x] Tests: 140 package tests, 16 UI tests
- [x] Owner: first real release (v0.1.0) made in Relvora (published 2026-10-23; release run 40005880104 attached the notarized app)
- [ ] Owner: choose a licence (PRODUCT_SPEC G10)

## 0.1.1 checklist

- [x] Project groups: schema V4 (lightweight migration, V3 fixture), backup format 5 ([ADR 0014](decisions/0014-project-groups.md))
- [x] Sidebar sections, Move to Group, drag and drop, group menu; grouped Dashboard, collapsed sidebar, quick actions, and Release History filter
- [x] Publish a draft from Relvora after a second confirmation; blocked when the draft no longer matches the review ([ADR 0015](decisions/0015-publish-from-relvora.md))
- [x] App icon from the owner's logo (`Design/logo.png`, `scripts/make-app-icon.swift`)
- [x] Package tests: 161 (21 new)
- [x] Migration checked on a copy of an M04 test store opened by the new build
- [x] UI tests: 18 pass locally, two new (groups: create, drag, Move to Group, delete; publishing from Relvora). They caught ⌥⌘N never firing (⌥N is a dead key), so New Group is ⌃⌘N
- [x] CI on PR #10 (lint, 161 package tests, build, 18 UI tests)
- [x] Owner: release v0.1.1 from Relvora (published 2026-10-23; release run 40021984629 attached the notarized app)

## 0.1.2 checklist

- [x] Version suggestion: rules from the release-note sections, on New Release Plan and on a plan being prepared
- [x] Release checklist per project: blocks the draft until ticked, frozen with the release; schema V5 (V4 fixture from 0.1.1), backup format 6
- [x] Package tests: 172 (11 new)
- [x] UI tests: 20 pass locally, two new (the checklist blocks the draft until ticked; a new plan starts with the suggested version). They caught the check results not refreshing after a checklist change
- [x] CI on PR #11 (lint, 172 package tests, build, 20 UI tests)
- [x] Owner: release v0.1.2 from Relvora (published 2026-10-26; release run 40369759257 attached the notarized app)

## 0.2.0 and 0.2.1 checklist

- [x] Update check: Relvora's own releases, read with the GitHub sign-in; at launch, daily, and from Check for Updates ([ADR 0017](decisions/0017-update-relvora-from-relvora.md))
- [x] Install: backup first, checksum, then the updater service (outside the sandbox) checks the zip, bundle ID, version, and signature (Developer ID, same team, notarized) and swaps the app in atomically; the previous version goes to the Trash
- [x] Relaunch through a relaunch ticket; the new copy waits for the old one before opening the data
- [x] Package tests: 193 (21 new); opt-in check of the published 0.1.2 app against the Release requirement. Also fixed a flaky group-backup test (two projects in one millisecond)
- [x] End to end with throwaway team-signed copies: 0.0.1 → 0.0.2 installed and relaunched; an ad-hoc 0.0.3 refused
- [x] UI tests: 22 pass locally, two new (the offered update and its refused demo download, skip, Check for Updates, Settings). They caught the Settings switch having no VoiceOver label
- [x] CI on PR #12 (lint, 193 package tests, build, 22 UI tests); merged
- [x] Claude creates tasks: an MCP server on 127.0.0.1 (Streamable HTTP, Host and Origin checks, access key in the Keychain) with `list_projects`, `list_tasks`, and `create_tasks`; Settings › Claude ([ADR 0018](decisions/0018-claude-creates-tasks.md))
- [x] Package tests: 211 (18 new); end to end with curl against the sandboxed app, and with Claude Code 2.1.309 against a test copy
- [x] UI tests: 24 pass locally, two new (a task created over MCP appears on the open Board and in Settings › Claude; a request without the key is refused)
- [x] CI on PR #13 (lint, 211 package tests, build, 24 UI tests); merged
- [x] Owner: released v0.2.0 (release run 40387061674) and installed it by hand once (0.1.2 has no updater)
- [x] Owner: released v0.2.1 (release run 40407742616); 0.2.0 installed it into `/Applications` by itself on 2026-10-26: found, installed by the updater service, and relaunched (the new copy waited 0 ms for the old one)
- [x] Owner: turned on Settings › Claude and ran the setup command; Claude Code reports Relvora as connected

## Next release checklist (0.2.2)

- [x] Notification rules in RelvoraCore: the four kinds, their wording and targets, "planned for today" at 9:00 on the planned date, publications announced once ([ADR 0019](decisions/0019-notifications.md))
- [x] Notifier: permission asked the first time; a banner only when Relvora isn't the active app; "planned for today" scheduled with macOS; clicks open the project, the plan, or the update sheet
- [x] Settings › Notifications: macOS's permission and a switch for each kind
- [x] Drafts waiting on GitHub checked every 5 minutes while Relvora is open, so a release published on GitHub is recorded and announced
- [x] Package tests: 216 (5 new)
- [x] UI tests: 25 pass locally, one new (a published draft, an update, and Claude's tasks are notified; a kind turned off stays quiet)
- [ ] CI on the PR
- [ ] Owner: release it; the first notification shows macOS's permission prompt
