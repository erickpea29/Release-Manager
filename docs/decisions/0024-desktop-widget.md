# 0024 — Desktop widget

- **Status:** Accepted (the owner chose it from the [roadmap](../ROADMAP.md), for 0.2.4).
- **Date:** 2026-10-26

## Context

The roadmap asks for a desktop widget: the progress of the next release of a chosen project, or of every project. It needs a widget extension and a container the app and the widget share.

Four facts shaped the design:

- **A widget runs in its own process,** sandboxed. It can't read the app's sandbox container, where the SwiftData store is.
- **Releases are Developer ID builds without provisioning profiles** ([ADR 0011](0011-distribution-developer-id.md)). CI, fresh clones, and UI tests build ad-hoc, with no team ([ADR 0007](0007-build-configuration-and-signing.md)).
- **macOS protects App Group containers.** An app uses a group without asking the user only if its signature allows it. Without that, macOS asks for consent, which would block launch and UI tests. On macOS 26.6.2, `containermanagerd` logs the decision when a copy launches:
  - team-signed, group prefixed with the team ID: "APPROVED. Requestor's signature allows it to access a TCC-protected group container";
  - ad-hoc: "REJECTED. … Group containers identifiers should be prefixed by requestor's team ID to allow access on this platform."
- **The updater checks nested code** ([ADR 0017](0017-update-relvora-from-relvora.md)), so whatever is inside the app must be signed with it.

## Decisions

1. **The shared container is an App Group prefixed with the team ID:** `<TeamID>.com.erickpea29.Relvora<suffix>`.
   - Both entitlements files name `$(TeamIdentifierPrefix)$(RELVORA_BUNDLE_ID_BASE)$(RELVORA_BUNDLE_ID_SUFFIX)`.
   - A team-prefixed group needs no provisioning profile, unlike a `group.` one. macOS approves it for an app signed by that team: Developer ID releases and Apple Development (`.dev`) builds alike.
   - Each build type has its own group, as it has its own bundle ID and data container: the release, `.dev`, `.adhoc`, and test suffixes never share a snapshot.
2. **The widget reads a snapshot, never the store.**
   - The app writes `WidgetSnapshot.json` to the group container. For each active project, in the sidebar's order: its name, icon, and group; the version being planned (version, title, status, tasks done of the tasks on its Board, planned date); and the last published release. The file has a format number.
   - It's written a second after the last change to the projects, the groups, or their numbers, only when the content changed, in one atomic replace. Then the app asks WidgetKit to reload the widget.
   - Only the app opens the store: no second process reads or migrates it, and there's no schema or backup format change.
   - The code is in a new package module, `RelvoraWidgetData` (the snapshot, how it's built, its file, the links), linked by the app and the widget. `ProjectStats` now also counts the tasks of the version being planned.
3. **Who writes it.**
   - Only a copy using the real data. A copy with an in-memory or test store, sample data, or a test settings suite never writes it, so the owner's widget never shows test data.
   - **Ad-hoc builds** have no team, so they never touch a group container and no prompt appears. Their widget says "Open Relvora". The extension is still built and embedded, so CI compiles it.
   - **For checks** (Debug only): `-RelvoraWidgetTestFolder <name>` writes the snapshot to `Widget Tests/<name>/`, in the group container when there is one, otherwise in the app's temporary folder, and logs it. The widget never reads that folder.
4. **The widget**: `RelvoraWidget.appex` in `Contents/PlugIns`, bundle ID `<app's bundle ID>.Widget`, sandboxed, with the App Group as its only entitlement.
   - **Small:** one project's next release: a progress ring, the version, tasks done of total, and the planned date, or the status when it's a draft or needs reconciliation. A date already passed is marked late.
   - **Medium and large:** every project with a version being planned (3 or 6, then "N more"), or the chosen project in more detail.
   - **Settings:** an optional project (`AppIntentConfiguration`). The project entity is the widget's own and reads the snapshot. With no project chosen, the small widget shows the first project with a version being planned.
   - **States:** no snapshot yet ("Open Relvora"), no projects, no versions planned, and a chosen project that was deleted or archived. The gallery shows the user's projects, or a blurred example when there are none.
   - **Design system:** semantic colors, status as an icon and words, the app's spacing. The ring, bars, and icons are accentable, for the tinted and clear widget styles. The timeline also refreshes at midnight, for "Today" and late dates.
5. **Links:** `relvora://project/<id>` opens the project and `relvora://dashboard` the Dashboard. The scheme is registered in Info.plist and handled with `onOpenURL`. A link that arrives before the projects are loaded waits for them; a project that no longer exists opens the Dashboard.
6. **Signing and notarization.**
   - The widget is signed like the app (`Shared.xcconfig`): ad-hoc, team, or Developer ID, with the hardened runtime, and without a profile.
   - The release archive and export sign it with the app, and notarization covers it.
   - `build-release.sh` now checks that the nested code (the updater service and the widget) has the hardened runtime, and that the app and the widget are entitled to the team's App Group.
   - The updater's check validates nested code, so it checks the widget as part of the app. A copy whose widget doesn't match its signature is refused.

## Consequences

- **Team-signed builds log a harmless line:** `taskgated-helper` says "no eligible provisioning profiles found" when the App Group is present. The app still runs, and `containermanagerd` approves the group.
- **The `relvora` scheme is claimed by every copy** (the release, `.dev`, and test builds). WidgetKit opens a widget's links in the app that contains it. A link opened elsewhere, such as from Terminal, goes to whichever copy macOS picks; an unknown project opens the Dashboard.
- **The widget can't be tried from a build folder.** macOS (`chronod`) doesn't keep the widgets of copies in build folders ("shouldn't cache it"). The first time it can be added to the desktop is with a copy in Applications, such as the 0.2.4 release.
- **Each update replaces the widget with the app.** A widget already on the desktop keeps working; macOS starts the new extension.
- No schema or backup format change. The snapshot is rebuilt from the store at every launch.

## Evidence

- **Package tests (11 new):** how the snapshot is built (sidebar order, groups, archived projects left out, only active plans and published releases); progress; the file (round trip, a damaged file or another format read as none, stable bytes); the team-prefix rule; no shared container for an unsigned process; and the links.
- **On macOS 26.6.2, with my own test copies** (never the owner's app or data):
  - **Team-signed** (`.widgettest`, Apple Development, no profile): the group was approved, the test snapshot was written, and no prompt appeared.
  - **Ad-hoc:** the group was rejected at launch, but the app never touches it, so no prompt appeared and it ran normally.
  - **Links:** a project's link opened that project in the running copy, and an unknown one opened the Dashboard. A copy launched by an unknown project's link opened the Dashboard.
- **The release path, with Apple Development instead of Developer ID** (`.widgettest`): the archive and an export with manual signing and no profile produced a universal app with the widget in `PlugIns`, the hardened runtime on all nested code, and the team's App Group in both. The updater's own check accepted it (Debug policy), and refused it after one file in the widget changed.
- **Layouts:** every size and state was drawn offscreen (`ImageRenderer`) in light and dark.
- **Not checked here:**
  - a Developer ID-signed, notarized build: it needs the Release workflow and its secrets;
  - the widget hosted by macOS on the desktop, and the tinted and clear styles: they need a copy in Applications.
