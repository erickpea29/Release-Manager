# 0017 — Updating Relvora from Relvora

- **Status:** Accepted (the owner chose it from the [roadmap](../ROADMAP.md)). Replaces "No automatic updates" in [DISTRIBUTION.md §4](../DISTRIBUTION.md#4-limitations).
- **Date:** 2026-10-26

## Context

Each release meant downloading the zip from GitHub, quitting Relvora, and replacing the app by hand. The roadmap asks Relvora to find its own new versions, check them, replace itself, and relaunch. It must never install a build that isn't signed, or is signed by someone else.

Three facts shaped the design:

- **The releases are in a private repository** (`erickpea29/Release-Manager`), so there's no public feed to read. Relvora already signs in to GitHub, and its token can read the repository's releases and download their files (Contents: read).
- **Relvora is sandboxed** ([ADR 0005](0005-credential-storage.md)). A sandboxed app can't write to `/Applications`. Anything it writes is quarantined. A child process it starts inherits the sandbox.
- **The release workflow already publishes what's needed** ([ADR 0011](0011-distribution-developer-id.md)):
  - a Developer ID-signed, notarized, stapled `Relvora-<version>.zip`;
  - its `Relvora-<version>.zip.sha256`.

  GitHub also records a SHA-256 digest for each release file.

## Decisions

1. **Where updates come from.** The published, stable releases of the repository named by `RELVORA_UPDATE_REPOSITORY` (`Config/Shared.xcconfig`, Info.plist `RelvoraUpdateRepository`), read with the user's GitHub sign-in.
   - Drafts, prereleases, and tags that aren't versions are ignored (`AppUpdateRules`).
   - The newest release above the running version that has both files uploaded is offered.
   - A newer release whose build isn't attached yet is reported as "on its way".
   - A sign-in that can't read the repository gets an explanation, not an error loop.
2. **When.**
   - Automatically at launch and once a day while Relvora runs (Settings › General › Updates, on by default). An automatic check only offers the version, in the sidebar; it never opens a window.
   - **Relvora › Check for Updates…** shows the result in a sheet, even for a version the user skipped.
   - Nothing is downloaded or installed until the user chooses **Install and Relaunch**.
3. **Installing**, in order. Any failure stops it, and nothing changes.
   1. Save a backup of all data to Safety Backups ("Before updating to x.y.z …"). A new version can change the data so the old one can't open it ([ADR 0016](0016-version-suggestion-and-release-checklist.md)).
   2. Download the checksum file, then the zip.
   3. Check the zip's SHA-256 against the checksum file, and against GitHub's digest when it has one.
   4. Hand the zip, as an open file, to the **updater service** (decision 4), which:
      - checks the SHA-256 again;
      - checks that every entry is inside one `.app` (no absolute paths, no `..`), and unpacks it with `ditto --noqtn`;
      - checks the app's bundle ID is the running app's, its version is the one offered, and it's newer than the installed one;
      - checks its signature (decision 5);
      - swaps it into place atomically (`renamex_np` with `RENAME_SWAP`) and moves the previous version to the Trash.
   5. Relaunch (decision 6).
4. **The updater service.**
   - `RelvoraUpdater.xpc`, inside the app (`Contents/XPCServices`), built from `Updater/` with the shared `RelvoraUpdates` module. It is **not sandboxed**: that's what lets it replace the app.
   - The same approach as Sparkle's installer service. Only its own app can connect to an XPC service in its bundle. When signed, it also requires the connecting app to be signed by the same team.
   - It replaces only the app that contains it, never a path it's given, and it makes every check again itself.
   - macOS's App Management protection lets an app's own team update it, and the service is signed by the same team. The end-to-end check below ran outside `/Applications`, so the first real update is the first test there. If macOS refuses, Relvora says so and nothing changes.
5. **Signature.** The updater's `SigningPolicy` requires, with `SecStaticCodeCheckValidity` (all architectures, nested code, strict, symlinks restricted):
   - **Release builds:** an Apple-anchored **Developer ID Application** certificate, the **running app's team ID** (read from the running signature, never stored), the **running app's bundle ID**, and **notarized** (the stapled ticket, or Apple's servers).
   - **Debug builds:** an Apple-issued certificate of the same team and the same bundle ID. This is for checking the installer locally. Release builds never use it.
   - A copy that isn't Developer ID signed (ad-hoc or unsigned test packages) doesn't check for updates.
   - The checksum only proves the download is the file GitHub has. The signature is what decides.
6. **Relaunching.** Two findings from the end-to-end check shaped this:
   - macOS drops the launch arguments a sandboxed app passes to an app it opens;
   - an open sheet stops an app from quitting ("termination blocked by modal sheet").

   So the installing copy leaves a **relaunch ticket** in its own settings (`RelaunchTicket`: its process ID, the version, the backup, and in Debug builds its launch options). It opens the new version as a new instance, waits until macOS has started it, closes the sheet, and quits. The new copy reads the ticket, which is valid for 60 seconds. It waits for the old process to exit before it opens the data, then shows "Relvora is updated to x.y.z", with the backup.
7. **Not included.**
   - Delta updates, and downgrades.
   - Updating while Relvora runs from a disk image or from macOS's temporary copy of a downloaded app (App Translocation). Relvora says to move it to Applications.
   - Updating a copy in a folder the user can't write to. Relvora says to install from the release page.

## Consequences

- Releasing is now: publish from Relvora, wait for the build, then **Install and Relaunch** on each Mac.
- **0.1.2 and older have no updater.** The first version with it must be installed by hand. Each later one can be installed from Relvora.
- **The release workflow's file names are now a contract:** `Relvora-<version>.zip` with `Relvora-<version>.zip.sha256`, a signed, notarized, stapled app, and a CFBundleShortVersionString equal to the tag's version. Renaming them, or attaching an unsigned build, stops updates; it can't install a bad one.
- People whose GitHub sign-in can't read the repository don't get updates: in practice, collaborators only. A public repository, or another download location, would change that.
- Each update leaves the previous app in the Trash and a backup in Safety Backups. Neither is cleaned up automatically.
- A new target, `RelvoraUpdater`, and a new module, `RelvoraUpdates`. No schema or backup format change.

## Evidence

- Package tests:
  - **release selection**, checksum and digest parsing;
  - **the asset API**: repository-name validation, and redirects that drop the token on other hosts or never leave HTTPS;
  - **the installer**, on temporary folders: install in place without quarantine, and every refusal leaving the app unchanged;
  - **signature requirements**: injection-safe; an Apple app refused for Developer ID;
  - **errors over XPC**, and the relaunch ticket.
- Opt-in (`RELVORA_RELEASE_APP`): the published 0.1.2 app meets the Release requirement, including notarization. The same app with another team ID, or another bundle ID, fails it.
- End to end on the owner's Mac, with throwaway team-signed copies (`.updatetest` bundle ID, never the owner's app or data):
  - 0.0.1 downloaded 0.0.2 from a local server through the demo GitHub, installed it, and relaunched;
  - the old process quit before the new one opened its data (the new copy logged a 0 ms wait: the old one had already quit);
  - the new copy showed the notice with the backup.
  - An ad-hoc signed 0.0.3 was refused ("isn't signed with Relvora's Developer ID"), and 0.0.1 stayed in place with a valid signature.
- **In use:** the owner's 0.2.0 in `/Applications` found 0.2.1 on 2026-10-26, installed it, and relaunched (macOS's App Management protection allowed the same-team updater; the new copy waited 0 ms).
- UI tests (22 pass, two new): an offered update is shown with its notes, the updater refuses the demo download, Skip and Check for Updates work, and the Settings section shows the result. They found the Settings switch had no VoiceOver label.
