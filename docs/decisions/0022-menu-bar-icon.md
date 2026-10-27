# 0022 — Menu bar icon

- **Status:** Accepted (the owner chose it from the [roadmap](../ROADMAP.md)).
- **Date:** 2026-10-26

## Context

The roadmap asked for a menu bar icon:
- versions in progress and drafts waiting, each one click from opening;
- a switch in Settings to turn it off.

Until now, seeing what's in progress meant bringing Relvora's window forward and opening the Dashboard.

## Decisions

1. **A menu, not a panel** (`MenuBarExtra` with the `.menu` style).
   - **Native:** it works like the system's menus, with the keyboard, VoiceOver, and a light or dark menu bar. It closes after a choice.
   - **Enough room:** each version is one item: its status icon, the project and version, and a second line with the status and progress ("Planned for 9 Nov · 1 of 7 tasks done"). macOS shows that line as the item's subtitle.
   - **A panel (`.window` style)** could show progress bars and badges. It would need its own layout, focus, and closing, for little more information.
2. **What it lists** (`ReleaseOverview` in RelvoraCore), across active projects:
   - **Drafts Waiting**, first: versions whose draft is on GitHub and not yet published, or that need reconciliation. These are the Dashboard's **Needs Attention**: "Draft created · not published yet", "Needs reconciliation · check GitHub".
   - **Versions in Progress:** the other versions being planned, with the planned date if there's one, and the project's tasks done (the Dashboard card's numbers).
   - **Each version once,** in the sidebar's order.
   - **Groups in a long list:** more than five versions in progress, from more than one sidebar section, are listed under each group's name, then **Other Projects**. A shorter list stays under one heading.
   - **Nothing planned:** "No Versions in Progress", with "Plan one in a project's Releases tab."
   - Then **Open Relvora**, **Settings…** (⌘,), and **Quit Relvora** (⌘Q).
3. **One click opens it.** Choosing a version brings Relvora forward, shows the main window, and opens the project's Releases tab, where the version being planned is selected first.
   - **The same navigation as a notification click** ([ADR 0019](0019-notifications.md)): `openProject(_:tab:)`.
   - **A closed main window opens again.** That can happen while Settings is open (decision 7). The window then takes the request when it appears.
4. **The icon is the logo's R,** as a template image (`MenuBarIcon`, built from `Design/logo.png` by `scripts/make-menu-bar-icon.swift`).
   - **How it's drawn:** the rounded square is opaque and the R is cut out, so macOS draws it in the menu bar's color.
   - **Why not an SF Symbol:** `r.square` was the alternative. At 16 points the logo's R is still clearly Relvora's.
5. **On by default; Settings › General turns it off** ("Show Relvora in the menu bar").
   - **In backups,** like the other settings of format 4 (appearance, GitHub refresh interval).
   - **No format change:** it's an optional field within format 6. Older files restore without it, and Relvora 0.2.3 ignores it.
6. **The icon appears once the projects have loaded.**
   - **Why:** with the icon present at launch, SwiftUI doesn't open the main window (checked on macOS 26.6.2).
   - **Inserted just after,** the window opens as before, and the menu has its data.
   - **If Relvora can't open its data,** there's no icon. The window shows the recovery screen.
7. **Closing the main window still quits Relvora,** and the icon goes with it.
   - **Today:** Relvora quits when its last window closes. Until 0.2.3 that came from SwiftUI, because the main window was the only `Window` scene. The Keyboard Shortcuts window (0.2.4) is a second one, which would keep Relvora running with no window, so an app delegate now says it with `applicationShouldTerminateAfterLastWindowClosed`.
   - **Why not keep running in the menu bar:** Relvora's start-up and its background checks run with the main window. Those are drafts every 5 minutes, CI every 2 minutes, and updates. Running without the window would mean moving them out of it. Otherwise the menu would show numbers that stop updating. This is possible later.
   - **While Settings is open,** Relvora keeps running after the main window closes, as before. Choosing a version opens the main window again.

## Consequences

- **From any app,** the versions in progress and the drafts waiting are one click away while Relvora is open.
- **The icon is there only while Relvora runs.** To keep it in the menu bar, keep Relvora open; its window can be minimized or hidden (⌘H).
- **Progress is the project's tasks done,** as on the Dashboard, not only the version's.
- **No schema or backup format change.** The switch is one more optional field in a backup's settings.

## Evidence

- **Package tests (4 new):**
  - drafts are listed first, and each version once;
  - a long list across groups is listed by group;
  - a short list, or one section, stays together;
  - nothing planned is empty.
  - The backup test also carries the switch, and restores a format 6 file without it.
- **Checked by hand on macOS 26.6.2,** with the Debug build on sample data and a throwaway settings suite. A temporary probe read the menu's items without opening the menu:
  - the main window opens at launch, and the icon appears once the projects load;
  - the menu lists "Versions in Progress" with "Relvora 0.2.0" and its subtitle and icon, then the three commands;
  - turning the switch off removes the icon, and turning it on brings it back;
  - closing the main window quits Relvora.
- **UI tests (3 new), not run yet:**
  - the switch hides and shows the icon;
  - a version opens its project's Releases tab from the Dashboard;
  - a draft waiting is listed apart and opens its plan.
