# 0019 — Notifications

- **Status:** Accepted (the owner chose it from the [roadmap](../ROADMAP.md)).
- **Date:** 2026-10-26

## Context

Relvora now does things while the owner works elsewhere:
- drafts get published on GitHub;
- new versions of Relvora appear;
- Claude Code adds tasks ([ADR 0018](0018-claude-creates-tasks.md)).

Some of it matters at a given time, like the day a version is planned for. Until now the owner learned about these things only by looking at the window.

The roadmap asked for:
- notifications such as "0.1.1 is published", "The build is attached", and "0.2.0 was planned for today";
- a switch for each kind in Settings;
- permission asked the first time a notification is needed.

## Decisions

1. **Four kinds** (`NotificationKind`), each on until turned off in **Settings › Notifications**:
   - **A release is published** (when Relvora verifies a publication on GitHub). Clicking opens the project's Releases tab.
   - **A version is planned for today** (9:00 on the plan's planned date). Clicking opens the project's Releases tab.
   - **A new Relvora is available** (the automatic update check finds a version, once per version). Clicking opens the update sheet.
     - This is "the build is attached" for Relvora itself: an update is offered only once its build is attached and uploaded ([ADR 0017](0017-update-relvora-from-relvora.md)).
     - For other projects, that's part of "Watch the build".
   - **Claude added tasks** (Claude Code creates tasks). Clicking opens the Board, or the Backlog.
2. **Noticing publications.**
   - **What's already published isn't announced.** A publication counts only when Relvora sees it for the first time after launch; what's published at launch, or after a restore, is only remembered.
   - **Drafts waiting on GitHub are checked every 5 minutes while Relvora is open,** with the same reconciliation as **Check Publication** ([ADR 0010](0010-release-workflow-and-reconciliation.md)). A draft published on github.com, or by a teammate, is recorded and announced without opening its plan.
   - **The check runs only while "A release is published" is on.** It costs a few requests per draft.
3. **"Planned for today" is scheduled with macOS** (`UNCalendarNotificationTrigger`), so it arrives even when Relvora is closed.
   - **When:** 9:00 local time on the planned day, for active plans of active projects, while that time is ahead.
   - **Kept up to date:** the scheduled notifications follow the plans whenever a project's numbers refresh. They change with the date, version, status, archiving, deletion, and the switch. Unchanged plans don't touch macOS.
4. **Permission and presentation.**
   - **macOS is asked the first time** a notification is to be delivered or scheduled. Settings shows the status, with **Allow Notifications…** before asking and **Open System Settings** when turned off.
   - **A banner only when Relvora isn't the active app.** Otherwise the notification goes straight to Notification Center, because the window already shows what happened.
5. **Tests never show real notifications.**
   - **Debug builds with a throwaway settings suite record notifications instead of showing them** (the UI tests and checks use one). Settings › Notifications lists what was recorded.
   - **The wording, timing, and "announce once" rules are pure functions** in RelvoraCore (`AppNotifications`), tested without macOS.

## Consequences

- **Nothing to watch:** the owner hears about publications, Relvora updates, Claude's work, and planned dates without keeping the window in view.
- **Drafts are reconciled in the background while Relvora is open.** A plan whose draft was published elsewhere is up to date before it's opened.
- **"Planned for today" can ask for permission early:** at launch, when a plan already has a planned date ahead.
- **Not covered:**
  - **builds of other projects:** that's "Watch the build";
  - **overdue versions** (a planned date that passed);
  - **notifications when Relvora isn't running**, apart from "planned for today".
- **No schema, backup, or GitHub permission change.** The switches are per-Mac settings, outside backups.

## Evidence

- Package tests (5 new):
  - the time and wording of "planned for today", across days and hours;
  - which plans are scheduled;
  - wording and targets for updates and Claude's tasks;
  - publications announced once, never for what was there before.
- UI test (25 pass, one new), with notifications recorded:
  - a draft published on the demo GitHub, an update found by the automatic check, and tasks created over MCP are each notified;
  - turning "Claude added tasks" off silences the next one.
