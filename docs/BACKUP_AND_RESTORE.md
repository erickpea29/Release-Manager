# Backup and Restore

Relvora keeps all data on your Mac. A backup is one JSON file containing every project (archived ones included) with its board columns, tasks, checklists, release plans, repository connections, and release history, plus your settings.

## Export a backup

**File › Export Backup…** (⇧⌘E), then choose where to save. The default name is `Relvora Backup <date>.json`.

Store backups somewhere other than your Mac's internal disk, such as an external drive or a cloud folder you trust.

## Restore a backup

1. **File › Restore from Backup…**, then choose a `.json` backup.
2. Relvora checks the whole file first. If anything is wrong, you get a specific message and **nothing changes**. Examples: a task pointing at a missing column, a project without a completion column, or a file from a newer Relvora version.
3. Relvora shows what the backup contains (date, number of projects and tasks) and asks for confirmation.
4. Before replacing anything, Relvora saves a **safety copy** of your current data. Afterwards, **Show in Finder** reveals it.
5. Restore replaces **all** current data in one step. If it fails partway, nothing is changed.

Safety copies are kept in Relvora's data folder:
`~/Library/Containers/com.erickpea29.Relvora…/Data/Library/Application Support/Relvora/Safety Backups/`. The exact folder name depends on your build (`.dev`, `.adhoc`, or the release build).

## What's included

| Included | Not included |
|---|---|
| Projects, including archived ones | Window state such as sidebar visibility and folded groups |
| Board columns and their order | GitHub sign-in (never exported; it stays in the Keychain) |
| Tasks: notes, labels, priority, type, checklist, order, completion | Cached GitHub data (re-downloadable) |
| Release plans: status, target commit, tag, notes | |
| GitHub repository connections (format 2) | |
| Release history: every snapshot, exactly as recorded (format 3) | |
| Settings: appearance, accent, window, columns for new projects, release-note label rules, GitHub refresh interval (format 4) | |
| Project groups, their order, and each project's group (format 5) | |

## File format

Pretty-printed JSON with `"formatVersion": 5` (format 1–4 files from earlier versions still restore: format 1–3 files keep your current settings, and format 1–4 files restore with no groups), ISO 8601 dates (millisecond precision), and readable enum values (`"priority": "high"`). Files are stable across export → restore → export. Boards restored from a backup made before the Backlog tab lose their Backlog column the first time the project opens (its tasks move to To Do; [ADR 0012](decisions/0012-backlog-tab-and-version-board.md)).

A newer app may write a higher `formatVersion`; older apps refuse such files instead of misreading them. For example, Relvora 0.1.0 can't restore a backup from 0.1.1, which has groups.

## Recovery checklist

- **Restored the wrong file?** Restore the safety copy from the Safety Backups folder.
- **The app can't open its data at launch?** It shows a recovery screen. Quit, then restore your latest backup (you may need a fresh store; see README › Debug launch options for development builds).
