import SwiftUI

/// The sidebar and the content as one frame. Hiding the sidebar narrows it to a strip of icons and showing it widens
/// it again, as a single piece. Its border runs into the content's top border with a rounded corner, so the toolbar
/// and the sidebar frame the content in an L.
///
/// This replaces `NavigationSplitView`, whose sidebar is a separate floating panel that slides out of the window.
struct SidebarContainer<Detail: View>: View {
    @Environment(Preferences.self) private var preferences
    @Binding var selection: SidebarItem?
    @SceneStorage("sidebarWidth") private var expandedWidth = SidebarLayout.defaultWidth
    @ViewBuilder let detail: Detail

    private var isExpanded: Bool { preferences.sidebarVisible }
    private var width: CGFloat { isExpanded ? expandedWidth : SidebarRail.width }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if isExpanded {
                    // Keeps its full width while narrowing, so the rows fade out instead of reflowing.
                    SidebarView(selection: $selection)
                        .frame(width: expandedWidth)
                        .transition(.sidebarContent)
                } else {
                    SidebarRail(selection: $selection)
                        .transition(.sidebarContent)
                }
            }
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color.chrome)
            .clipped()
            .overlay(alignment: .trailing) {
                if isExpanded { SidebarResizeHandle(width: $expandedWidth) }
            }

            // On the window's own background (the translucent material stays still: AppKit views don't follow
            // SwiftUI animations, so a material behind the content lagged behind the moving corner).
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Drawn on the content itself, so the corner moves exactly with it while the sidebar animates.
                .overlayPreferenceValue(ContentTopBorder.self) { border in
                    ContentFrame(contentTopBorder: border)
                }
        }
        // The toolbar shares the sidebar's color, in either window material.
        .background(alignment: .top) {
            Color.chrome
                .frame(height: 0)
                .ignoresSafeArea(edges: .top)
        }
        .animation(.smooth(duration: 0.3), value: isExpanded)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(isExpanded ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                    preferences.sidebarVisible.toggle()
                }
                .help(isExpanded ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
            }
        }
    }
}

extension AnyTransition {
    /// The outgoing content fades out quickly and the incoming one fades in over the second half, so the list and
    /// the icons never show at once while the sidebar changes width.
    fileprivate static var sidebarContent: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.15)),
            removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
}

enum SidebarLayout {
    static let defaultWidth: Double = 240
    static let widths: ClosedRange<Double> = 200...360
}

/// View › Show/Hide Sidebar (⌃⌘S), in place of `SidebarCommands`, which only works with `NavigationSplitView`.
struct SidebarToggleCommand: View {
    let preferences: Preferences

    var body: some View {
        Button(preferences.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
            preferences.sidebarVisible.toggle()
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

/// Drag the sidebar's border to resize it.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var widthAtDragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .trailing))
            .offset(x: 3)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        let range = SidebarLayout.widths
                        width = min(max(start + drag.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .accessibilityHidden(true)
    }
}

/// The sidebar's border: a line down its right side that turns, with a rounded corner, into the content's top border.
/// The top border is the content's own top bar line when it has one (under the board's filter bar), otherwise the
/// bottom of the toolbar.
private struct ContentFrame: View {
    let contentTopBorder: Anchor<CGRect>?

    var body: some View {
        GeometryReader { proxy in
            let edge = ContentEdge(
                corner: CGPoint(x: 0, y: contentTopBorder.map { proxy[$0].minY } ?? 0), radius: Radius.panel)
            ZStack {
                // Outside the rounded corner, the content is covered in the sidebar's color.
                CornerFill(edge: edge).fill(Color.chrome)
                edge.stroke(.separator, lineWidth: 1)
            }
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The content's top and left edges with a rounded top-left corner. It extends past the bottom and right, which are
/// clipped.
private struct ContentEdge: Shape {
    let corner: CGPoint
    let radius: CGFloat

    /// The line's center, on the pixels a 1-point divider would use.
    func path(in rect: CGRect) -> Path {
        outline(in: rect, inset: 0.5)
    }

    /// The outline `inset` points in from the corner. The corners are concentric, so the line keeps its width.
    func outline(in rect: CGRect, inset: CGFloat) -> Path {
        let origin = CGPoint(x: corner.x + inset, y: corner.y + inset)
        let size = CGSize(
            width: max(rect.maxX - origin.x, 0) + 2 * radius,
            height: max(rect.maxY - origin.y, 0) + 2 * radius)
        return Path(
            roundedRect: CGRect(origin: origin, size: size), cornerRadius: radius + 0.5 - inset, style: .continuous)
    }
}

/// The corner outside the line's outer edge. The line itself lies over the content along its whole length, so it
/// looks the same everywhere.
private struct CornerFill: Shape {
    let edge: ContentEdge

    func path(in rect: CGRect) -> Path {
        let square = CGRect(origin: edge.corner, size: CGSize(width: 2 * edge.radius, height: 2 * edge.radius))
        return Path(square).subtracting(edge.outline(in: rect, inset: 0))
    }
}

/// The line under the content's top bar, when it has one. The sidebar's border turns into it.
struct ContentTopBorder: SwiftUI.PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this line as the content's top border, which the sidebar's border turns into.
    func contentTopBorder() -> some View {
        anchorPreference(key: ContentTopBorder.self, value: .bounds) { $0 }
    }
}
