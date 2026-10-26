import RelvoraCore
import SwiftUI

/// The collapsed sidebar: while the sidebar is hidden, it narrows to a strip of icons that keeps the overview and every
/// active project one click away. Projects show their initials, in the sidebar's order, with a line between groups;
/// the full name is in the tooltip and for VoiceOver.
struct SidebarRail: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: Spacing.xs) {
            destination(.dashboard, title: "Dashboard", help: "Dashboard (⌘1)") {
                Image(systemName: "square.grid.2x2")
            }
            destination(.history, title: "Release History", help: "Release History (⌘2)") {
                Image(systemName: "clock.arrow.circlepath")
            }
            Divider()
                .padding(.horizontal, Spacing.xs)
            ScrollView {
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, Spacing.s)
                        }
                        ForEach(section.projects) { project in
                            destination(
                                .project(project.id), title: project.name, help: help(for: project), filled: true
                            ) {
                                Text(project.initials)
                                    .font(.system(size: 12, weight: .semibold))
                                    .minimumScaleFactor(0.7)
                            }
                            .contextMenu { ProjectContextMenu(project: project) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            if let update = model.updates.offered {
                Button {
                    model.updates.showOffered()
                } label: {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                }
                .buttonStyle(RailButtonStyle(isSelected: false, isFilled: false))
                .accessibilityLabel("Relvora \(update.version.description) is available")
                .help("Relvora \(update.version.description) is available")
            }
            Button {
                model.projectEditor = .new
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(RailButtonStyle(isSelected: false, isFilled: false))
            .accessibilityLabel("New Project")
            .help("New Project (⇧⌘N)")
        }
        .padding(.vertical, Spacing.xs)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("sidebarRail")
    }

    static let tileSize: CGFloat = 32
    static let width = tileSize + 2 * Spacing.xs

    private func destination(
        _ item: SidebarItem, title: String, help: String, filled: Bool = false, @ViewBuilder icon: () -> some View
    ) -> some View {
        let isSelected = selection == item
        return Button {
            selection = item
        } label: {
            icon()
        }
        .buttonStyle(RailButtonStyle(isSelected: isSelected, isFilled: filled))
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help)
    }

    /// Groups without projects have nothing to show here.
    private var sections: [ProjectSection] { model.projectSections.filter { !$0.projects.isEmpty } }

    /// "Pilou › Web — 0.4.0"
    private func help(for project: Project) -> String {
        let name = model.group(of: project).map { "\($0.name) › \(project.name)" } ?? project.name
        guard let version = model.stats[project.id]?.activePlanVersion else { return name }
        return "\(name) — \(version)"
    }
}

/// A square tile: the accent color when selected, a light fill on hover (always, for project initials).
private struct RailButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isFilled: Bool

    func makeBody(configuration: Configuration) -> some View {
        RailTile(isSelected: isSelected, isFilled: isFilled, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct RailTile<Label: View>: View {
    let isSelected: Bool
    let isFilled: Bool
    let isPressed: Bool
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
        label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: SidebarRail.tileSize, height: SidebarRail.tileSize)
            .background(background, in: shape)
            .contentShape(shape)
            .opacity(isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        if isHovered { return AnyShapeStyle(.quaternary) }
        return isFilled ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)
    }
}
