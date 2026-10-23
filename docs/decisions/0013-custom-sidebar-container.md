# 0013 — Relvora's own sidebar instead of NavigationSplitView

- **Status:** Accepted (first-release polish)
- **Date:** 2026-10-23

## Context

The owner asked for three things from the sidebar:
- When hidden, it should leave a strip of icons, flush with the window's edges.
- The strip and the toolbar should share one color, framing the content in an L with a rounded corner.
- Opening and closing should look like **one component**.

On macOS 26, `NavigationSplitView`'s sidebar is a floating Liquid Glass panel. It can only slide out of the window, and its width can't be animated into a strip. A strip added beside it always looked like a second component.

## Decisions

1. **`SidebarContainer`** replaces `NavigationSplitView`.
   - An `HStack` of the sidebar and the content.
   - The sidebar's width animates between the full list and a 48-point icon strip (`SidebarRail`), and the two cross-fade inside it.
   - It keeps what the system sidebar did:
     - ⌃⌘S (**View › Hide/Show Sidebar**), replacing `SidebarCommands`, and a toolbar button;
     - resizing by dragging (200–360 points, per window);
     - the visibility preference;
     - project search, now a field in the sidebar, since `.searchable(placement: .sidebar)` needs a split view;
     - focus on the project list when the window opens.
2. **One color.**
   - The sidebar, the toolbar band, and filter bars use the toolbar's color (`Color.chrome`).
   - In the translucent window, only the content shows the material, as the window's own background.
3. **The L frame** (`ContentFrame`): the sidebar's 1-point border turns, with a rounded corner, into the content's top border.
   - A tab marks its own top line with `contentTopBorder()`; otherwise the border runs under the toolbar.
   - It is drawn on the content, so it moves exactly with it.
4. **Nothing that animates is an AppKit view.**
   - AppKit views (`NSVisualEffectView`) don't follow SwiftUI animations.
   - A material behind the content lagged behind the moving corner and showed a strip outside it. It was removed for this reason.

## Consequences

- **The open sidebar changes look.** It is flush, opaque, and framed, instead of the floating glass panel. It looks the same open and closed.
- **Relvora keeps the sidebar behavior up to date itself.** System behavior is lost:
  - automatic collapse in narrow windows;
  - the glass sidebar's look in future macOS releases.
- **UI tests find the project list** as before (an outline). The accessibility audit covers the new search field and the strip.
