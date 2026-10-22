# M05 — Design Polish and Distribution Report

Status: **Implemented, awaiting review** (PR pending) · 2026-10-22

## 1. What was built

| Area | Implementation |
|---|---|
| Settings | Four tabs:<br>• **General:** appearance (System/Light/Dark), accent color (System plus 7 swatches), and window (Opaque/Translucent).<br>• **Board:** columns for new projects, edited in place, validated, and saved when valid; with Restore Defaults.<br>• **Releases:** pull-request label → release-notes section rules.<br>• **GitHub:** sign-in.<br>One `Preferences` store replaces the scattered `@AppStorage` (keys unchanged) and drives the window, new projects, release notes, and backups |
| Appearance | Light, dark, and system for every view. The accent is applied with `.tint`, so selection rings, drop indicators, progress bars, and buttons follow it. The translucent window keeps opaque reading surfaces. Reduce Transparency and Increase Contrast force the opaque window, and Settings says why |
| Dashboard | **Needs Attention** lists drafts waiting on GitHub and plans needing reconciliation, each opening the release plan. **Recent Releases** shows the last five verified publications, opening Release History. The project cards keep their progress and last release |
| Keyboard | Board:<br>• Arrow keys move a selection across cards and columns.<br>• Return or Space opens a card; Delete deletes it after confirmation.<br>• New **Task** menu: Open ⌘O, move ⌥⌘←/→/↑/↓, Delete ⌘⌫. Enabled only while the board has focus.<br>• The board is reachable with Tab.<br>New **Go** menu:<br>• Quick Actions ⌘K, Dashboard ⌘1, Release History ⌘2, and project tabs ⌥⌘1–3.<br>• Quick Actions searches projects, tabs, and actions (new task or plan, backup, restore, settings); ↑↓ choose and Return runs |
| Accessibility | Labels for all controls and containers. Cards are buttons with VoiceOver actions to move them. Icon-only links have spoken labels (`GitHubLinkIcon`). Status badges use full-strength text, with color only on the icon and capsule. Xcode's accessibility audit runs in the UI tests (§2) |
| UI tests | New `RelvoraUITests` target and shared scheme. Every test uses an in-memory store, the demo GitHub, and a throwaway settings suite. Helpers type real Space key presses (F23) and attach screenshots and, on a timeout, the accessibility tree |
| Error states | Demo GitHub has **Go Offline / Go Online** (and `-RelvoraDemoGitHubOffline YES`) for testing offline and cached states. A timed-out create is covered by a scenario |
| Backups | Format 4 adds the settings (G12). Formats 1–3 still restore and keep the current settings |
| Distribution | Notarized Developer ID builds ([ADR 0011](decisions/0011-distribution-developer-id.md)):<br>• `scripts/release/build-release.sh` archives, signs, verifies, notarizes, staples, and zips.<br>• `.github/workflows/release.yml` runs it when a GitHub release is published, attaches the app, and does an unsigned dry run without secrets or on pipeline pull requests.<br>• CI adds a UI-test job |
| Docs | [INSTALLATION.md](INSTALLATION.md) covers install, build, first launch, GitHub authorization, backups and recovery, data locations, uninstall, and troubleshooting. [DISTRIBUTION.md](DISTRIBUTION.md) covers the one-time Apple and GitHub setup, releasing, and limitations. Also updated: DESIGN_SYSTEM (accent, keyboard map, audit rules), DATA_MODEL (preferences), and BACKUP_AND_RESTORE (format 4) |

## 2. Verification

| Check | Result |
|---|---|
| `swift test` | **130 tests in 30 suites pass** (3 new: board templates, label rules, preferences in backups); 2 opt-in tests skipped |
| UI tests (`xcodebuild test`) | **12 of 12 pass** locally (about 2 minutes):<br>• Launch and dashboard.<br>• Quick actions and Go shortcuts.<br>• Create a project, add a task, and move it with ⌥⌘→ and the Task menu; Return opens it.<br>• **Release flow on the demo GitHub:** prepare, create the draft (the confirmation stays disabled until incomplete tasks are confirmed), publish, Check Publication, Release History.<br>• **Timeout:** Needs reconciliation, then Check GitHub links the draft.<br>• **Offline:** refresh keeps the cached data with "You're offline", and the release check explains the problem without creating anything.<br>• Settings: appearance, accent, and window.<br>• The board template applies to new projects.<br>• **Accessibility audit** of the dashboard, board, and release plan |
| Accessibility audit | The first run found real problems, all fixed:<br>• cards without a role;<br>• an unlabeled filter field;<br>• icon links read as `arrow.up.right.square`;<br>• a tag field and the Generate split button without labels;<br>• small secondary digits and captions failing contrast;<br>• a capsule badge failing contrast on a selected row.<br>Platform behavior accepted with narrow, documented rules (DESIGN_SYSTEM §6, F24) |
| Release pipeline, locally | The ad-hoc path built a **universal** (arm64 and x86_64) app, `com.erickpea29.Relvora`, version 0.0.0, with the hardened runtime and sandbox entitlements, the public client ID, and **no demo code**. The signed and notarized path needs the owner's secrets |
| Settings isolation | After the UI tests, the owner's `.dev` settings were unchanged: appearance `system`, no accent written. The tests used their own suite |
| Strict lint and builds | **0 findings** (now including `UITests`); Debug and Release builds with 0 warnings |
| macOS versions | Minimum **26.0** (deployment target, `LSMinimumSystemVersion` 26.0). Tested on **26.6.2** (this Mac) and on the CI `macos-26` image (version in the CI log). 26.0 itself wasn't run: it would need a macOS 26.0 virtual machine. The compiler checks every API against the 26.0 deployment target |
| CI | Pending on the M05 pull request |

## 3. Acceptance criteria

| Criterion | Status |
|---|---|
| Core workflows are usable in both light and dark appearance | **PASS**: UI tests run in light; screenshots in dark, translucent, and purple |
| Translucency has a readable fallback | **PASS**: reading surfaces stay opaque; Reduce Transparency and Increase Contrast force opaque (ADR 0006) |
| Core UI interactions are keyboard-accessible | **PASS**: board selection, moves, open and delete, menus, quick actions, and shortcuts (UI test) |
| Tests cover the most important end-to-end flows | **PASS**: 12 UI tests, including the full release flow and error states, plus 130 package tests |
| A clean build and installation procedure is documented | **PASS**: [INSTALLATION.md](INSTALLATION.md) |
| Signing and notarization limitations are documented for the intended distribution method | **PASS**: [DISTRIBUTION.md](DISTRIBUTION.md) §4 and ADR 0011 |

## 4. Owner actions

1. **Developer ID setup** ([DISTRIBUTION.md §1](DISTRIBUTION.md#1-one-time-setup-owner)): create a Developer ID Application certificate (as Account Holder), export it as `.p12`, create an App Store Connect API key, and add the six GitHub secrets. Then run **Actions › Release › Run workflow** to check.
2. **Licence** (G10): choose one before distributing to others.

## 5. Findings

- **F23 — `typeText` drops spaces in SwiftUI text fields (macOS 26, XCUITest).** `typeText("a b")` produced `ab`, while `typeKey(.space)` into the same field worked, so the app is fine. The tests type words and real Space key presses.
- **F24 — The accessibility audit flags text in selected list rows.** White on the accent color (about 5.4:1 by calculation) and dark text on the gray unfocused selection are both reported as contrast failures, even though screenshots show high contrast. The audit accepts contrast findings only inside the currently selected row; all other text is audited.
- **F25 — The UI test runner is sandboxed.** It can't write files elsewhere, so screenshots and the accessibility tree are XCTest attachments, read with `xcrun xcresulttool export attachments`.
- **F26 — Settings reopens on the last tab used, across launches.** Tests select their tab explicitly.
- **F27 — A shared demo cache leaked stale data between launches.** One run showed another run's snapshot as "Cached data from 8 hours ago". The demo cache is now per launch.
- **F29 — CI renders at 1x, where the contrast audit misreads small text.** GitHub's macOS runners use a non-Retina virtual display (1024×674 screenshots). Black text on a light-gray sidebar was flagged there, though the same screens pass on Retina displays. On 1x displays, contrast is not audited; every other check still runs. Contrast is enforced locally.
- **F30 — Sidebar and toolbar contrast varies from run to run.** On macOS 26 they are Liquid Glass drawn over whatever is behind the window. The sidebar row "Website Redesign" and the window title failed intermittently (1 of 3 runs). Contrast findings in those system-chrome areas are accepted; the detail content is fully audited. It was stable in 4 of 4 runs afterwards.
- **F28 — My verification captured the owner's own Relvora window.** A capture by app name picked the owner's window. Test instances are now launched, captured, and quit only by their own process ID; the stray image was deleted.

## 6. Known issues and notes

- Automatic updates (Sparkle) aren't included; users download new releases.
- A release build has its own data container and needs a new GitHub sign-in. Move data with a backup.
- The audit's accepted platform behavior is narrow and listed in `UITests/AccessibilityUITests.swift`. Review it when Xcode changes.
- Release-note label rules apply to pull request labels. Tasks keep their type-based sections.
