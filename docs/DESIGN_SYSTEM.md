# Design System

Status: finished in M05. Material rules follow [ADR 0006](decisions/0006-window-materials.md).

## 1. Principles

- **Native first:** standard SwiftUI controls, toolbars, menus, `Settings` scene, and keyboard shortcuts behave as they do in Apple's apps. The sidebar is Relvora's own, so it can narrow to an icon strip as one piece ([ADR 0013](decisions/0013-custom-sidebar-container.md)).
- **Content over chrome:** release data and text sit on calm, readable surfaces. Effects are restrained.
- **The system decides when it can:** on macOS 26, sidebars and toolbars get Liquid Glass automatically. Do not imitate or override it.

## 2. Navigation

A sidebar holds **Dashboard**, **Release History**, and the projects; each project has the tabs **Backlog**, **Board**, **Releases**, and **GitHub**. Settings is its own scene (⌘,), with the tabs General, Board, Releases, GitHub, Notifications, and Claude.
- **Notifications.** A banner only when Relvora isn't the active app; otherwise straight to Notification Center. A click opens the project's tab, or the update sheet ([ADR 0019](decisions/0019-notifications.md)).

- **Groups.** Projects are listed by group, one collapsible section each, then **Other Projects** (**Projects** while there are no groups). A group's heading has its menu (new project, rename, move up or down, delete); an empty group says "No projects" and takes dropped projects. Projects change groups by drag and drop, **Move to Group**, or the project editor ([ADR 0014](decisions/0014-project-groups.md)).
- **Collapsed sidebar.** Hiding the sidebar (⌃⌘S or the toolbar button) narrows it to a strip of icons: Dashboard, Release History, each active project by its initials in the sidebar's order, with a line between groups (the group and name in the tooltip), and New Project. It widens again as the same piece; the list and the icons cross-fade.
- **The L frame.** The sidebar and the toolbar share the toolbar's color and frame the content in an L. One 1-point line runs down the sidebar's edge and turns, with a 14-point rounded corner, into the content's top border: the line under a tab's filter bar, or the bottom of the toolbar. The line and corner are drawn on the content, so they move with it while the sidebar animates.
- **Resizing.** Drag the sidebar's edge (200–360 points, remembered per window).
- **Board and Backlog.** The Board shows the version being planned; the Backlog tab lists that version above everything else unfinished ([ADR 0012](decisions/0012-backlog-tab-and-version-board.md)).
- **Updates.** A newer Relvora found by the automatic check appears as one accent-colored line above the sidebar's buttons ("Relvora 0.2.0 is available"), or an icon in the collapsed sidebar; it never opens a window by itself. **Relvora › Check for Updates…** and the line open the update sheet: the notes, then **Install and Relaunch**, with each step shown while it runs ([ADR 0017](decisions/0017-update-relvora-from-relvora.md)).

### App icon

The white **R** on a dark rounded square (0.1.1). The source is `Design/logo.png`. `scripts/make-app-icon.swift` builds `App/Assets.xcassets/AppIcon.appiconset` from it, on Apple's macOS icon grid: an 824-point rounded square with continuous corners on a 1024-point canvas, with a soft shadow. macOS 26 shows it as a full icon, with its own glass edge, not inside a gray tile. To change the icon, replace the logo and run:

```sh
swift scripts/make-app-icon.swift Design/logo.png App/Assets.xcassets/AppIcon.appiconset
```

## 3. Tokens

| Token | Value |
|---|---|
| Spacing | 4, 8, 12, 16, 24, 32 pt |
| Corner radius | 6 (controls/chips), 10 (cards), 14 (panels) |
| Typography | System text styles only: `.largeTitle` (page titles), `.title2`/`.title3` (sections), `.headline` (card titles), `.body`, `.callout`, `.caption` (metadata). Monospaced (`.monospaced()`) for SHAs, tags, and versions |
| Color | Semantic only: `.primary`/`.secondary`/`.tertiary` labels, `Color(nsColor: .controlBackgroundColor)` and `.windowBackgroundColor` surfaces, and the app accent for emphasis. No hard-coded RGB in views |
| Accent | **Settings › General**: System (default), Blue, Purple, Pink, Red, Orange, Green, Graphite. Applied with `.tint`; views use `.tint`, never `Color.accentColor`. No yellow, which fails contrast in the light appearance |
| Status | Planned (secondary), Draft created (blue), Published (green), Needs reconciliation (orange), Cancelled (secondary). Always an icon plus text, never color alone. Badges have full-strength text, with the color on the icon and capsule. In list rows, status is an icon plus text with no capsule (`RowStatusLabel`), so it follows the selection's text color |

## 4. Appearance and materials

- Appearance: System, Light, or Dark, applied with `preferredColorScheme`.
- Window material: **Opaque** (default) or **Translucent**. Translucent uses a full-window `NSVisualEffectView` (`.behindWindow`).
  SwiftUI `ultraThinMaterial` window backgrounds are not used, because secondary text loses contrast over saturated backdrops (M00 §2.4).
- The sidebar's visibility is stored as a preference and applied explicitly; it is never left to window state restoration.
- In the translucent window, only the content shows the material. The sidebar, the toolbar band, and the filter bars use the toolbar's opaque color (`Color.chrome`), so they read as one piece. Nothing that animates is an AppKit material: AppKit views don't follow SwiftUI animations.
- Reading surfaces (cards, Kanban columns, editors, changelog) always use an opaque or thick-material panel.
- Reduce Transparency or Increase Contrast forces Opaque.

## 5. States

Every remote-data view defines all five states:

| State | Treatment |
|---|---|
| Empty | `ContentUnavailableView` with one primary action |
| Loading | Inline `ProgressView`; cached content stays visible while refreshing |
| Offline / cached | Banner showing "Showing cached data from <time>" and a Retry button |
| Error | Plain-language message, a suggested fix, and Retry. Permission errors name the missing GitHub permission |
| Content | — |

## 6. Accessibility and keyboard

- **Labels.** Every interactive element has an accessibility label.
  - Icon-only buttons use `Label` with `.labelStyle(.iconOnly)`.
  - Icon-only links use `GitHubLinkIcon`, which adds a tooltip and a spoken label.
  - Containers (board columns, plan lists, the projects grid) have labels.
- **Keyboard map.**

  | Keys | Action |
  |---|---|
  | ⌘K | Quick actions: go to a project, tab, or view, or run an action |
  | ⌘1 / ⌘2 | Dashboard / Release History |
  | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘4 | Backlog / Board / Releases / GitHub of the open project |
  | ⌃⌘S | Hide or show the sidebar (it narrows to an icon strip) |
  | ⌘N / ⇧⌘N / ⌃⌘N | New task / New project / New group (not ⌥⌘N: ⌥N is a dead key on many keyboards, and the shortcut never fires) |
  | Arrow keys (board focused) | Move the card selection, across columns with ← → |
  | Return or Space | Open the selected card |
  | ⌥⌘← / ⌥⌘→ | Move the selected card to the previous / next column (**Task** menu) |
  | ⌥⌘↑ / ⌥⌘↓ | Move the selected card up / down (**Task** menu) |
  | ⌘O | Open the selected card (**Task** menu) |
  | ⌘⌫ or ⌫ | Delete the selected card, after confirmation |
  | Return / ⌫ (Backlog) | Open / delete the selected task |
  | ⌘R | Refresh a repository |
  | ⇧⌘E | Export backup |

  - The board can be reached with Tab, even with macOS keyboard navigation off.
  - Task commands are enabled only while the board itself has focus, so ⌘⌫ and ⌥⌘ arrows still work in text fields.
  - Moving a task never requires drag-and-drop. VoiceOver users get **Move to Previous/Next Column** actions on each card.
- **Automated audit.** UI tests run Xcode's accessibility audit on the dashboard, the board, the Backlog, and a release plan.
  - Our own findings are fixed, not suppressed.
  - Accepted platform behavior, kept narrow and listed in `UITests/AccessibilityUITests.swift`:
    - SwiftUI pickers and menus expose "show menu" rather than "press".
    - AppKit window and split-view containers have no description.
    - The title-bar sidebar button reports a parent/child mismatch.
    - The system secondary text color "nearly passes" at small sizes; Increase Contrast strengthens it.
    - Text inside a selected list row uses the system selection colors (F24).
    - Sidebar and toolbar contrast varies with what is behind the window, because they are drawn on Liquid Glass (F30).
  - Contrast is audited on Retina displays only. On CI's 1x display, small text measures low even when it is black on light gray (F29).
- **Contrast.** Text meets WCAG AA contrast (4.5:1 for body text) in both appearances with the opaque material. Small numbers and status text use full-strength text, because small secondary text on tinted backgrounds failed the audit.
