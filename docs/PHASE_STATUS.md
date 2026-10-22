# Phase Status

| Phase | Status |
|---|---|
| M00 — Technical Validation | **Complete** (2026-10-21) |
| M01 — Foundation | **Complete**: merged in PR #1 ([report](M01_FOUNDATION.md)) |
| M02 — Projects and Kanban | **Complete**: merged in PR #2 ([report](M02_PROJECTS_AND_KANBAN.md)) |
| M03 — GitHub Integration | **Complete**: merged in PR #3 ([report](M03_GITHUB_INTEGRATION.md)) |
| M04 — Release Workflow and History | **Merged** in PR #5, fix in PR #6 ([report](M04_RELEASE_WORKFLOW.md)); live publication check pending |
| M05 — Design Polish and Distribution | Not started |

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
- [ ] Owner: publish or delete that draft on GitHub, then verify **Check Publication** ([report §4](M04_RELEASE_WORKFLOW.md#4-live-draft-check-owner))
