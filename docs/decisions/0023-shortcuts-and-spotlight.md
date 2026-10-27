# 0023 — Shortcuts and Spotlight

- **Status:** Accepted (the owner chose it from the [roadmap](../ROADMAP.md)).
- **Date:** 2026-10-26

## Context

The roadmap asked for:
- App Intents: "Add a task to Relvora" and "What's the next release of …";
- tasks and projects found in Spotlight.

The facts that shaped the design:

- **Only the running app writes Relvora's data** ([ADR 0018](0018-claude-creates-tasks.md)). An App Intents extension would be a second process writing the store. So the intents live in the app target, and macOS opens Relvora to run them when it isn't open.
- **On macOS 26, Spotlight lists app entities** (`IndexedEntity`) and opens them with their Open intent. A Core Spotlight item can be linked to its entity (`associateAppEntity`).
- **Claude already creates tasks** through `create_tasks`. A task added from Siri should follow the same rules.
- **UI tests and checks run copies of Relvora with sample data.** They must never put that data in the owner's Spotlight.

## Decisions

1. **What Shortcuts and Siri offer** (`App/Features/Intents`):
   - **Add a Task:** a project, a title, and optionally a type, a priority, and notes.
     - It goes to the version being planned. It goes to the Backlog when no version is planned, or when **Add To** is Backlog.
     - **The rules are Claude's** (`TaskCreationService`, moved from RelvoraMCP to RelvoraCore): the task is checked like one typed in the app, goes at the end of the first column, and is refused in an archived project.
     - **No label.** The user asked for the task; the label "claude" marks Claude's work.
     - It answers "Added “Fix login” to Relvora 0.2.4." and returns the task.
   - **Get the Next Release:** the version being planned, its status, how many of its tasks are done, and its planned date.
     - Siri says it, and Shortcuts shows it: "The next release of Relvora is 0.2.4 (Spotlight). 3 of 8 tasks are done. It’s planned for November 2, 2026."
     - It returns a **Release** with the same values. The wording is in RelvoraCore (`VersionProgress`).
   - **Open Project** and **Open Task**, which Spotlight uses too.
   - **Phrases**, each naming the app as macOS requires: "Add a task to Relvora", "Add a task to <project> in Relvora", "What's the next release of <project> in Relvora", "What's the next release in Relvora", and a few more.
   - **Entities:** Project, Task, and Release.
     - Projects are found by name, description, or group; tasks by title, notes, labels, or project.
     - Archived projects aren't offered.
2. **The intents run inside Relvora.**
   - At launch, the app registers its model with `AppDependencyManager`. Intents use the same store and services as the window.
   - **A task added from Shortcuts shows at once:** Relvora refreshes the project as it does for Claude's tasks, so an open Board reloads.
   - **Add a Task and Get the Next Release run in the background.** When Relvora isn't open, macOS opens it first, and its window opens as at any launch.
   - **The Open intents bring Relvora forward.** If its window was closed, Relvora asks SwiftUI to reopen it, as a click on the Dock icon does.
3. **What Spotlight lists** (`SystemSearch`):
   - **Active projects,** with their group and the version being planned.
   - **Their tasks on the Board** (the version being planned, done or not) **and in the Backlog.** Each task shows its project, version, and column. Its labels, type, priority, and the first 2,000 characters of its notes can be searched.
   - **Not listed:** archived projects and their tasks, and tasks finished outside the version, such as those of past releases.
   - **Opening a result:** each item is a Core Spotlight item (`project-<id>`, `task-<id>`) linked to its entity. Clicking it opens the project on its Board, or the task's editor on the Board or in the Backlog. Either Open Task or the user activity Spotlight hands over does this.
4. **Keeping Spotlight current** (`SpotlightIndex`):
   - **Two seconds after a change,** once for several changes. Changes include tasks, plans, projects, groups, a restore, and tasks from Claude or Shortcuts.
   - **Only new and changed items are sent.** Deleted, archived, and finished items are removed.
   - **At launch, Relvora clears what an earlier run indexed** and indexes again, because it can't know what's there.
   - **Siri learns the project names** for the phrases whenever they change.
5. **Privacy and test copies.**
   - **Everything stays on the Mac.** The intents run in Relvora, Spotlight's index is local, and nothing is sent anywhere.
   - **Settings › General › Spotlight** turns indexing off, which removes what was indexed. It's on by default, and it's a per-Mac setting, outside backups.
   - **Test copies never touch Spotlight or Siri's phrases.** A test copy is one with an in-memory store, sample data, a throwaway settings suite, the demo GitHub, or another store name. So UI tests and checks can't fill the owner's Spotlight with sample data.

## Consequences

- From Siri, Spotlight, or a shortcut, the owner can add a task or ask for the next release without switching to Relvora. Any open task can be found by typing in Spotlight.
- **Relvora opens to run an intent** when it's closed, and its window comes with it.
- **Development builds have their own bundle IDs** (`.dev`, `.adhoc`), so they have their own App Shortcuts and Spotlight items, separate from the installed Relvora.
- **RelvoraMCP keeps only Claude's wording;** the rules are shared. Some of Claude's messages about a bad task now use the shared wording, such as "Task 2: There’s no column “QA”. The columns are To Do, In Progress, Review, Done."
- **No schema, backup, entitlement, or GitHub permission change.**

## Evidence

- Package tests (9 new):
  - **adding tasks:** into the version, at the end of the first column, with their details; to the Backlog, by choice or with no version planned; refused without a version when one is required; nothing created when any task is invalid; archived projects refused;
  - **the next release:** the wording for progress, status, and planned dates (ahead, today, past);
  - **what Spotlight lists:** active projects, the version's tasks and the Backlog, nothing archived or finished in a past version; identifiers; only changed items sent again; task search.
- **A test copy** (in-memory store, sample data) ran the intents and queries in the app process:
  - Add a Task put "Task from Shortcuts" on the open Board at once, as a bug with high priority and no label;
  - a project with no version planned got the task in its Backlog;
  - an archived project was refused ("Command-Line Tools is archived. Unarchive it in Relvora first.") and isn't offered;
  - Get the Next Release answered for 0.2.0 and returned nothing for a project with no version;
  - the Spotlight items were built for the sample data (3 projects and 10 tasks), without indexing.
- **UI tests** (2 new): a Spotlight result opens its task on the Board, or in the Backlog, with its editor. They use a Debug launch option, because Spotlight can't be driven from a UI test.
- **Not verified yet:**
  - running the intents from the Shortcuts app and Siri;
  - real Spotlight results and clicks, because test copies never index;
  - how the window appears when macOS opens Relvora for an intent, and reopening a closed window from Spotlight.
