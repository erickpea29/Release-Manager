# 0012 — Backlog tab and a Board for the version being planned

- **Status:** Accepted (first-release polish; the owner chose this model)
- **Date:** 2026-10-23

## Context

The Board showed every task, with a "Backlog" column first. The owner asked for the backlog to become its own tab, listed with the work of the version being planned, "like a sprint". Two models were considered:
- **Not in the version:** the Backlog is every unfinished task outside the version being planned, and the Board shows only that version. This works like Jira sprints and needs no schema change.
- **The Backlog column:** the column moves to the tab, and the Board keeps showing every task. This needs a schema change to mark the column, and a task could be in the backlog and in the version at the same time.

The owner chose the first.

## Decisions

1. **The release plan decides where a task is** (`VersionScope` in RelvoraCore). Its column is its status in either place.
   - **Board:** the tasks of the active release plan. With no plan active, the Board offers to plan a version.
   - **Backlog:** unfinished tasks outside it, including any a released or cancelled version left unfinished. Ordered most urgent first, then oldest first.
   - **Done Outside a Version:** a collapsed section for finished tasks that are in no published release, so no task disappears.
2. **The Backlog tab** lists the version above the Backlog.
   - Moving a task between them changes only its release plan; the task keeps its column.
   - Tasks move with a row button, by drag and drop, or from the context menu.
   - The Board's card menu has **Move to Backlog**.
   - Tasks added on the Board join the version; tasks added in the Backlog don't.
3. **No Backlog column.**
   - The default columns are To Do, In Progress, Review, Done.
   - "Backlog" is a reserved column name, in boards and in the template for new projects (`ValidationError.reservedColumnName`).
   - **Existing boards:** when a project opens, a board's old Backlog column folds into To Do, keeping the tasks' order and versions, in one saved change. A board without To Do renames the column To Do instead, so no task is marked as started.
   - **Saved templates and older backups:** a saved template drops the Backlog column, and older backups restore unchanged and are folded the same way.
4. **Tabs and shortcuts:** Backlog | Board | Releases | GitHub, ⌥⌘1–4. The Board stays the default tab.

## Consequences

- The Board reads as the work in progress for one version. Unfinished tasks without a version leave the Board and appear in the Backlog.
- Columns are visible only on the Board, so a new project plans a version before its columns show. The Backlog still shows each task's column.
- The Backlog has no manual ranking. Ordering by priority needs no schema change; a rank field is a possible later step.
- Folding the Backlog column changes stored data once per board. It is atomic and tested (`BoardPlannerTests`, `BoardAndBackupIntegrationTests`).
