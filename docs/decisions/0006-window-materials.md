# 0006 — Window materials and translucency

- **Status:** Accepted (visual check 2026-10-21)
- **Date:** 2026-10-19

## Context

The plan asks for an optional translucent window with a readable opaque fallback, using supported APIs. M00 compared three modes, in light and dark, over a high-contrast test pattern ([evidence](../M00_TECHNICAL_VALIDATION.md#24-window-translucency-pass-visual-check-2026-10-21)):
- **SwiftUI** `containerBackground(.ultraThinMaterial, for: .window)` is strongly translucent. Secondary and tertiary text placed directly on it loses contrast over saturated colors.
- **AppKit** `NSVisualEffectView` (`underWindowBackground`, `.behindWindow`) is visibly translucent but muted, and all text stays readable in both appearances.
- `NavigationSplitView` sidebars and toolbars get Liquid Glass automatically on macOS 26 in every mode.

## Decision

- **Default: Opaque window material.** System Liquid Glass chrome still applies; it is system-managed and honors accessibility settings.
- **Translucent option:** a full-window `NSVisualEffectView` (`underWindowBackground`, `.behindWindow`, `followsWindowActiveState`), installed with `containerBackground(for: .window) { … }`.
- Primary reading surfaces (cards, Kanban columns, editors, changelog text) still sit on opaque or thick-material panels. This is a hierarchy rule, not a readability workaround.
- When `accessibilityReduceTransparency` (or Increase Contrast) is on, force Opaque regardless of preference.
- Appearance (system/light/dark) is independent, applied via `preferredColorScheme`.

## Consequences

- One `NSViewRepresentable` (about 15 lines); no private APIs.
- Inactive windows flatten their material. This is macOS behavior and acceptable.
- Polish for M05: the toolbar band stays opaque in translucent mode and leaves a seam.
- Sidebar visibility is stored as a preference and applied explicitly, because window restoration reopened it collapsed.
- Verification of translucency needs region screenshots; window-only captures hide the backdrop.
