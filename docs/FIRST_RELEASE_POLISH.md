# First-Release Polish

Status: **Merged** (PR #9) · 2026-10-23

Changes the owner asked for before trying the first release, built and checked one at a time with the owner.

## 1. Changes

| Area | Change |
|---|---|
| Sidebar | Relvora's own sidebar ([ADR 0013](decisions/0013-custom-sidebar-container.md)):<br>• Hiding it leaves a strip of icons, flush with the window's edges.<br>• It shares the toolbar's color and frames the content in an L, with a 1-point border and a rounded corner.<br>• Opening and closing animate it as one piece.<br>• Resizable, with its own project search. |
| Backlog | A **Backlog** tab lists the version being planned above every other unfinished task ([ADR 0012](decisions/0012-backlog-tab-and-version-board.md)).<br>• Tasks move with a row button, drag and drop, or the context menu.<br>• The Board shows only that version, with its progress in the top bar.<br>• With no version planned, the Board offers to plan one. |
| Columns | Default columns are To Do, In Progress, Review, Done. "Backlog" is reserved; an old Backlog column folds into To Do when the project opens. |
| GitHub | The repository open in the GitHub tab refreshes automatically: every 5 minutes by default, set in **Settings › GitHub** and kept in backups. "Synced … ago" stays current. |
| Fixes | • Release History with no releases pulled the collapsed sidebar to the middle of the window.<br>• Release plans and Release History are now centered in wide windows.<br>• The new search field no longer takes focus when the window opens.<br>• New text fields have accessibility labels, and checklist counts have enough contrast. |
| Smaller | • Projects have `initials` for the strip.<br>• `-RelvoraInitialView dashboard|history` launch option (Debug).<br>• Quick actions include each project's Backlog. |

## 2. Verification

- **Package tests:** 140 pass, including new ones for:
  - which tasks are on the Board and in the Backlog, and the Backlog's order;
  - folding the Backlog column, on the planner and the real store;
  - the reserved name;
  - the refresh schedule;
  - the backup field and initials.
- **UI tests:** 16 pass locally, including the collapsed sidebar, moving tasks Backlog → version → Board → Backlog, the GitHub refresh setting, and a new accessibility audit of the Backlog.
  - Local runs build the app as `com.erickpea29.Relvora.uitests`, so they never quit the owner's development build.
- **Visual checks:**
  - Screenshots of a separate test instance, in light, dark, and translucent windows.
  - The sidebar animation, recorded frame by frame at 1/13 speed, closing and opening.
  - A copy of an old-format board (Backlog | Doing | QA | Done) opened as To Do | Doing | QA | Done, with its backlog task in the Backlog tab.
- **Automatic refresh,** checked with a 20-second interval: the label went from 5 to 17 seconds, refreshed on its own, then counted up again.
- **Signed release pipeline:** verified (manual runs 39870619573 and 39876742407; [DISTRIBUTION.md](DISTRIBUTION.md)).
- **CI on PR #9.**

## 3. Notes for the owner

- Opening a project in this build removes its old Backlog column once (its tasks move to To Do). Export a backup first if you want a way back.
- Tab shortcuts moved: ⌥⌘1 Backlog, ⌥⌘2 Board, ⌥⌘3 Releases, ⌥⌘4 GitHub.
