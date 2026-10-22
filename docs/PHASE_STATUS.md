# Phase Status

| Phase | Status |
|---|---|
| M00 — Technical Validation | **Complete** (2026-10-21) |
| M01 — Foundation | **Complete**: merged in PR #1 ([report](M01_FOUNDATION.md)) |
| M02 — Projects and Kanban | **In review**: CI pending, owner manual checks ([report](M02_PROJECTS_AND_KANBAN.md)) |
| M03 — GitHub Integration | Not started |
| M04 — Release Workflow and History | Not started |
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
- [ ] CI on PR: **pending**
- [ ] Owner manual interaction checklist ([report §5](M02_PROJECTS_AND_KANBAN.md#5-not-verified-automatically-manual-checklist-for-the-owner))
