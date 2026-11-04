# 0026 — Claude plans in Relvora

- **Status:** Accepted. On 2026-11-03 the owner asked for "almost full control" for Claude, beyond the roadmap's *Claude edits tasks*. Asked what to leave out, they chose **GitHub and deleting projects or groups**. Asked how to guard deletions, they chose **Claude Code's own permission prompt** over a switch in Relvora. Supersedes decisions 2 and 6 of [ADR 0018](0018-claude-creates-tasks.md); its transport, safeguards, and setup stay.
- **Date:** 2026-11-03

## Context

ADR 0018 let Claude Code read projects and create tasks, and nothing else. In practice, a session that plans a release also wants to finish the job:
- tick a checklist step;
- move a task to Review, or complete it;
- plan the next version, and move Backlog tasks into it;
- tidy a duplicate away.

Until now, each of those went back to the owner as "please do this in Relvora".

What stays true:
- Relvora's data is written only by the running app, through the same services as its own views.
- Every GitHub write is confirmed by the user in Relvora.
- Nothing leaves the Mac.

## Decisions

1. **Fifteen tools, by area.** Each change goes through the service the app's own views use, with the same rules.

   | Area | Tools | Rules |
   |---|---|---|
   | Reading | `list_projects` (now with `includeArchived`), `list_tasks`, `list_versions` | — |
   | Tasks | `create_tasks` (unchanged), `update_tasks`, `delete_tasks` | `TaskEditingService` (new, beside `TaskCreationService`) |
   | Versions | `plan_version`, `update_version`, `cancel_version`, `delete_version` | `ReleasePlanService`, `ReleasePlanRules` |
   | Columns | `add_column`, `update_column`, `delete_column` | `BoardService`, `BoardPlanner` |
   | Projects | `create_project`, `update_project` | `ProjectService`, `ProjectGroupService` |

2. **Tasks.** `update_tasks` changes up to 50 tasks at a time. A change can set:
   - the title, notes, type, priority, and labels;
   - the checklist, given whole, so a tick is the list sent again; steps whose title is unchanged keep their identity;
   - the column, or `done`: the completion column marks a task done, and leaving it marks it not done;
   - whether the task is in the version being planned or in the Backlog;
   - its position, before another task.

   As with `create_tasks`, every change is checked before any is made. Only created tasks get the label **claude**: an edited task isn't Claude's. `delete_tasks` deletes up to 50 tasks in one change, or none when an id is unknown.
3. **Versions.** The plan rules are the app's:
   - one version is planned at a time;
   - only a version that's still *planned* can be edited or cancelled;
   - only *planned* and *cancelled* versions can be deleted.

   A version with a draft on GitHub, or a published one, is a record. Claude can tick or untick the steps of the project's release checklist on the version, but it can't change the checklist itself. Dates are days (`2026-11-20`) on the Mac's calendar.
4. **Columns and projects.**
   - Columns follow the board rules: the completion column and a board's last column can't be deleted, and a column with tasks needs somewhere to move them.
   - New projects start with the board in **Settings › Board**.
   - A group Claude names is created if it doesn't exist.
   - Claude won't create a project with the name of an existing one; the app still allows it.
   - **Archived projects are read-only to Claude**, except for unarchiving.
5. **Off-limits.** No tool:
   - deletes a project or a group, which would take their release history;
   - touches GitHub: repositories, drafts, publishing, pull requests;
   - changes settings, the access key, the project's release checklist, or backups.
6. **Deletions are guarded by Claude Code, and announced by Relvora.**
   - `delete_tasks`, `cancel_version`, `delete_version`, and `delete_column` carry MCP's `destructiveHint`. Claude Code asks before each call, unless the user has allowed the tool.
   - Their descriptions and the server's instructions tell Claude to delete only what the user asked to remove.
   - A new notification kind, *Claude deleted or cancelled something*, says what went (on by default; Settings › Notifications turns it off).
   - There's no separate switch in Relvora.
7. **The app follows along.**
   - Every change refreshes the project's numbers and reloads its open workspace, as in ADR 0018. Changes to a project also reload the sidebar.
   - An editor whose task or version Claude deleted, or whose version ended, closes rather than failing on Save.
   - **Settings › Claude** lists what Claude can and can't do, and its last five changes.

## Consequences

- A Claude Code session can carry a plan through to the end: plan the version, fill it, keep the Board current, and close it out, up to the GitHub draft, which stays the owner's.
- **Deleting and cancelling can't be undone.** The guard is Claude Code's prompt, which the user can choose to skip. Backups (**File › Export Backup…**) remain the way back.
- **The access key is worth more.** It now allows deletions, not only additions. Its threat model is unchanged: it keeps out other users, web pages, and other machines, and anything running as the user can already read `~/.claude.json`.
- Claude's edits and the app's are last-writer-wins, as between two windows. An open task editor that saves after Claude's change keeps the editor's version.
- **No schema, backup, or GitHub permission change.**

## Evidence

- **Package tests:** 301 pass (21 new).
  - Task editing on a SwiftData store: the editor's rules, done in and out of the completion column, nothing changed by an invalid batch, placement, deleting all or nothing, archived projects.
  - The tools on an in-memory store: edits and ticks, moves and completion, positions, refusals, deletions, the destructive annotations, versions (listing, editing, one at a time, cancelling, deleting), columns, projects and groups.
  - The new notification.
- **UI tests:** the new `testClaudeEditsCompletesAndDeletesTasksOnTheBoard` plays Claude Code. It creates a task, then renames, re-prioritizes, and completes it, and it shows in Done. It deletes another task, which leaves the open Board. Settings › Claude lists both changes. It passes, with the 8 other UI tests this change can affect: Claude, Board, notifications, the Board and Backlog accessibility audits, and launch.
