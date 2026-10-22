# Design System

Status: foundations for M01; finished in M05. Material rules follow [ADR 0006](decisions/0006-window-materials.md).

## 1. Principles

- **Native first:** standard SwiftUI controls, `NavigationSplitView`, toolbars, menus, `Settings` scene, and keyboard shortcuts behave as they do in Apple's apps.
- **Content over chrome:** release data and text sit on calm, readable surfaces. Effects are restrained.
- **The system decides when it can:** on macOS 26, sidebars and toolbars get Liquid Glass automatically. Do not imitate or override it.

## 2. Navigation

A sidebar holds **Dashboard**, **Projects** (with each project's Kanban and Releases), **Release History**, and the **Settings** scene (⌘,). The detail column changes with the selection. Inspectors (`.inspector`) handle task and release details.

## 3. Tokens

| Token | Value |
|---|---|
| Spacing | 4, 8, 12, 16, 24, 32 pt |
| Corner radius | 6 (controls/chips), 10 (cards), 14 (panels) |
| Typography | System text styles only: `.largeTitle` (page titles), `.title2`/`.title3` (sections), `.headline` (card titles), `.body`, `.callout`, `.caption` (metadata). Monospaced (`.monospaced()`) for SHAs, tags, and versions |
| Color | Semantic only: `.primary`/`.secondary`/`.tertiary` labels, `Color(nsColor: .controlBackgroundColor)` and `.windowBackgroundColor` surfaces, and the app accent for emphasis. No hard-coded RGB in views |
| Accent | User-selectable from a fixed palette that passes contrast in both appearances; defaults to the system accent |
| Status | Planned (secondary), Draft created (blue), Published (green), Needs reconciliation (orange), Cancelled (tertiary). Always shown with an icon and text, never color alone |

## 4. Appearance and materials

- Appearance: System, Light, or Dark, applied with `preferredColorScheme`.
- Window material: **Opaque** (default) or **Translucent**. Translucent uses a full-window `NSVisualEffectView` (`.behindWindow`).
  SwiftUI `ultraThinMaterial` window backgrounds are not used, because secondary text loses contrast over saturated backdrops (M00 §2.4).
- The sidebar's visibility is stored as a preference and applied explicitly; it is never left to window state restoration.
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

- Every interactive element has an accessibility label. Icon-only buttons use `Label` with `.labelStyle(.iconOnly)`.
- Full keyboard paths:
  - ⌘N new task, ⇧⌘N new project, ⌘F search, ⌘R refresh, ⌫ delete (with confirmation).
  - Arrow keys move the selection.
  - Moving a task between Kanban columns also has a keyboard path (menu command), not only drag-and-drop.
- Text meets WCAG AA contrast (4.5:1 for body text) in both appearances with the opaque material.
