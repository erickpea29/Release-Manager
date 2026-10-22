# M02 — Projects and Kanban Report

Status: **Complete**, merged in PR #2 · 2026-10-22. The §5 manual checklist was not reported back before merging.

## 1. What was built

| Area | Implementation |
|---|---|
| Projects | Create, edit (name, description), archive and unarchive, delete (with confirmation and cascade), search in the sidebar; archived section; dashboard cards with progress and next version |
| Release plans | Releases tab: create, edit (planned only), cancel, delete (planned or cancelled). Rules: one active plan per project; versions unique by SemVer precedence (cancelled plans excepted); live version hint in the editor |
| Kanban columns | Add (placed before a trailing completion column), rename, move left/right, make completion column (updates task completion), delete (empty, or move its tasks to a chosen column first; the completion column and last column are protected) |
| Drag and drop | Drop a card on a card to place it before that card, or on a column's empty space to append. Order uses fractional keys with renormalization when gaps run out. **Keyboard/menu path:** card context menu › Move To, and the editor's Column picker |
| Tasks | Quick add per column; editor sheet with title, column, priority, type, release plan, labels, Markdown notes, checklist (add/toggle/edit/remove), timestamps, delete. Entering or leaving the completion column sets or clears completion |
| Filters | Text (title, notes, labels; case- and accent-insensitive, all terms), priority, type, labels, release (any/none/plan), hide completed; counts per column and overall |
| Backup | File › Export Backup (versioned JSON) and Restore from Backup: validate first, confirm, automatic safety copy, then all-or-nothing replace ([guide](BACKUP_AND_RESTORE.md)) |
| States | Loading, empty (board, column, releases, dashboard, search), error banner with Retry, alerts with recovery suggestions, store-failure screen |
| Core | `BoardPlanner` (pure board operations → `BoardChanges`), `BoardService`, `ReleasePlanRules`/`ReleasePlanService`, `ProjectService`, `TaskFilter`/`TextSearch`, `BackupDocument`/`BackupValidator`/`BackupService` |
| Persistence | `apply(BoardChanges)`: one atomic batch with integrity checks (task ↔ column ↔ project, exactly one completion column, empty-before-delete). Backup export and replace-all. Fresh `ModelContext` per operation ([ADR 0008](decisions/0008-fresh-context-per-operation.md)) |

Schema: still **V1**. No storage changes were needed, so there is no migration.

## 2. Findings

- **F14 — `ModelContext.rollback()` is not a safe undo.** After a rejected batch, a property change on an already-fetched object (a column rename, a completion flag) survived in the shared context. It made a later integrity check pass that should have failed. Fixed by using a fresh context per operation (ADR 0008). The atomic-batch and store-integrity tests cover it.
- **F15 — Truncation loses milliseconds.** Date formatting styles truncate fractional seconds, and `.123` is stored as `.12299…`, so backups drifted by 1 ms per export/restore cycle. Fixed by rounding to the nearest millisecond; the round-trip test is now byte-stable.
- **F16 — Width-driven sidebar collapse was persisted.** A split view collapses the sidebar automatically when the detail column's minimum width doesn't fit. The two-way sidebar binding saved that as the user's preference (`sidebarVisible = 0`). Fixed by letting the filter bar scroll instead of imposing a minimum width.

## 3. Verification

| Check | Result |
|---|---|
| `swift test` (Packages/RelvoraKit) | **49 tests in 13 suites pass**, 3 consecutive runs. New: board planner (moves, completion, renormalization, columns), filters, release-plan rules, backup format/validator, project service, board/plan integration on disk, backup fixture round-trip |
| Strict lint | **0 findings** |
| App build | **Succeeded, 0 warnings** (team-signed `.dev`) |
| Real app, seeded store `M02Verification` | Board, sidebar (search, plan badge, archived section), and Releases tab render in light and dark. Relaunch shows identical board order. Sidebar stays visible after the F16 fix |
| CI | **PASS**: PR #2, run 39725532755 on `macos-26` (lint, 49/49 tests, app build) |

Representative dataset: `Tests/RelvoraPersistenceTests/Fixtures/backup-v1.json`. It has 2 projects (one archived), custom columns including a fractional position, 5 tasks with notes, labels, checklists and completion, and release plans in planned, published, and cancelled states. It restores into an empty store and exports back to identical content, and it restores over existing data with the same IDs.

## 4. Acceptance criteria

| Criterion | Status |
|---|---|
| Users can manage projects and tasks entirely offline | **PASS**: no network code exists yet |
| Task ordering persists after relaunch | **PASS**: integration test on an on-disk store + real-app relaunch |
| Tasks remain associated with valid projects and columns | **PASS**: enforced in `BoardPlanner` and again in the store (tests bypass the planner to prove it) |
| Backup and restore work on a representative test dataset | **PASS**: fixture round-trip, replace-in-place, invalid file leaves data intact |
| UI supports loading, empty, and error states where applicable | **PASS** (see §1 States) |

## 5. Not verified automatically (manual checklist for the owner)

UI tests are not set up yet; driving the app needs Xcode's automation permission. Please try:

1. Drag a card within a column and to another column, including into and out of **Done**; relaunch and check the order.
2. Card context menu › **Move To**.
3. Open a task: edit fields, add, toggle and remove checklist items, change column, assign a release, then **Save**.
4. Column menu: **Rename**, **Move Left/Right**, **Make Completion Column**, **Delete** (empty, and with tasks).
5. Filters: text, menus, **Hide completed**, **Clear**.
6. Releases: create a plan, try a second (blocked), cancel, then create again; delete.
7. Projects: edit, archive and unarchive, delete; sidebar search.
8. **File › Export Backup**, change something, **File › Restore from Backup**: confirm, then **Show in Finder** for the safety copy.

## 6. Known issues

- No UI-test target yet (planned for M05 per the implementation plan).
- New projects always get the five default columns. Configurable defaults in Settings are deferred (documented in DATA_MODEL).
- Checklist items can't be reordered by drag yet (their order is creation order).
- With a filter active, drop positions are relative to the visible cards. The task is placed before the card it was dropped on, which is correct, but hidden cards keep their places.
