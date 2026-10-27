import RelvoraCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var query = ""
    @SceneStorage("showArchivedProjects") private var showArchived = false
    /// The groups the user folded, as comma-separated IDs.
    @SceneStorage("collapsedGroups") private var collapsedGroups = ""
    @FocusState private var isListFocused: Bool

    private var sections: [ProjectSection] {
        ProjectGrouping.sections(model.activeProjects, groups: model.groups, query: query)
    }

    var body: some View {
        List(selection: $selection) {
            if query.isEmpty {
                Section("Overview") {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                        .tag(SidebarItem.dashboard)
                    Label("Release History", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.history)
                }
            }
            ForEach(sections) { section in
                if let group = section.group {
                    Section(isExpanded: isExpanded(group)) {
                        projectRows(section.projects, groupID: group.id)
                        if section.projects.isEmpty {
                            EmptyGroupRow { drop($0, into: group.id) }
                        }
                    } header: {
                        Text(group.name)
                            .contextMenu { GroupContextMenu(group: group) }
                            .accessibilityIdentifier("group-\(group.name)")
                    }
                } else {
                    Section(model.groups.isEmpty ? "Projects" : "Other Projects") {
                        projectRows(section.projects, groupID: nil)
                    }
                }
            }
            if let message = emptyMessage {
                Section("Projects") {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.archivedProjects.isEmpty {
                Section("Archived", isExpanded: query.isEmpty ? $showArchived : .constant(true)) {
                    ForEach(ProjectSearch.filter(model.archivedProjects, query: query, groups: model.groups)) {
                        project in
                        row(project)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focused($isListFocused)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSearchField(query: $query)
                .padding([.horizontal, .top], Spacing.s)
                .padding(.bottom, Spacing.xxs)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                UpdateAvailableButton()
                HStack {
                    Button("New Project", systemImage: "plus") { model.projectEditor = .new }
                        .help("New Project (\(KeyCommand.newProject.glyphs))")
                    Spacer()
                    Button("New Group", systemImage: "folder.badge.plus") { model.groupEditor = .new(moving: nil) }
                        .labelStyle(.iconOnly)
                        .help("New Group (\(KeyCommand.newGroup.glyphs))")
                }
            }
            .buttonStyle(.borderless)
            .padding(Spacing.s)
        }
        // The list, not the search field, has focus when the window opens, as in a system sidebar. AppKit focuses
        // the first text field as the window appears, so this runs just after.
        .task { isListFocused = true }
    }

    /// Shown where the project sections would be: before the first project, or when a search matches nothing.
    private var emptyMessage: String? {
        if !query.isEmpty {
            let archived = ProjectSearch.filter(model.archivedProjects, query: query, groups: model.groups)
            return sections.isEmpty && archived.isEmpty ? "No matches" : nil
        }
        return model.hasLoaded && sections.isEmpty ? "No projects yet" : nil
    }

    /// Projects can be dragged between sections to change their group.
    private func projectRows(_ projects: [Project], groupID: UUID?) -> some View {
        ForEach(projects) { project in
            row(project)
                .draggable(project.id.uuidString) {
                    Label(project.name, systemImage: project.iconName ?? "shippingbox")
                        .padding(Spacing.xs)
                        .background(.background, in: RoundedRectangle(cornerRadius: Radius.control))
                }
        }
        .dropDestination(for: String.self) { items, _ in _ = drop(items, into: groupID) }
    }

    private func row(_ project: Project) -> some View {
        Label(project.name, systemImage: project.isArchived ? "archivebox" : (project.iconName ?? "shippingbox"))
            .badge(model.stats[project.id]?.activePlanVersion.map { Text($0) })
            .tag(SidebarItem.project(project.id))
            .contextMenu { ProjectContextMenu(project: project) }
    }

    private func drop(_ items: [String], into groupID: UUID?) -> Bool {
        let ids = Set(items.compactMap(UUID.init(uuidString:)))
        let moving = model.projects.filter { ids.contains($0.id) && $0.groupID != groupID }
        guard !moving.isEmpty else { return false }
        Task { for project in moving { await model.setGroup(project, groupID) } }
        return true
    }

    private var collapsed: Set<String> { Set(collapsedGroups.split(separator: ",").map(String.init)) }

    /// Every group is open while searching, so no match is hidden.
    private func isExpanded(_ group: ProjectGroup) -> Binding<Bool> {
        guard query.isEmpty else { return .constant(true) }
        let id = group.id.uuidString
        return Binding(
            get: { !collapsed.contains(id) },
            set: { isExpanded in
                var ids = collapsed
                if isExpanded { ids.remove(id) } else { ids.insert(id) }
                collapsedGroups = ids.sorted().joined(separator: ",")
            }
        )
    }
}

/// The only row of an empty group: says so, and takes dropped projects.
private struct EmptyGroupRow: View {
    let onDrop: ([String]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Text(isTargeted ? "Move Here" : "No projects")
            .font(.callout)
            .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .dropDestination(for: String.self) { items, _ in
                onDrop(items)
            } isTargeted: {
                isTargeted = $0
            }
            .selectionDisabled()
            .help("Drag projects here, or use Move to Group in a project’s menu.")
    }
}

/// Filters the projects in the sidebar. Escape clears it.
private struct SidebarSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search projects", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search projects")
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
    }
}

/// Edit, group, archive, and delete: the same menu in the sidebar and the collapsed sidebar.
struct ProjectContextMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        Button("Edit Project…") { model.projectEditor = .edit(project) }
        Menu("Move to Group") {
            Picker(
                "Group",
                selection: Binding(
                    get: { project.groupID },
                    set: { groupID in Task { await model.setGroup(project, groupID) } })
            ) {
                Text("No Group").tag(UUID?.none)
                ForEach(model.groups) { group in
                    Text(group.name).tag(UUID?.some(group.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Group…") { model.groupEditor = .new(moving: project) }
        }
        Button(project.isArchived ? "Unarchive" : "Archive") {
            Task { await model.setArchived(project, !project.isArchived) }
        }
        Divider()
        Button("Delete Project…", role: .destructive) { model.projectPendingDeletion = project }
    }
}

/// New project, rename, reorder, and delete, on a group's heading.
struct GroupContextMenu: View {
    @Environment(AppModel.self) private var model
    let group: ProjectGroup

    private var index: Int? { model.groups.firstIndex { $0.id == group.id } }

    var body: some View {
        Button("New Project in “\(group.name)”…") { model.projectEditor = .newInGroup(group.id) }
        Divider()
        Button("Rename Group…") { model.groupEditor = .rename(group) }
        Button("Move Up") { Task { await model.moveGroup(group, by: -1) } }
            .disabled(index == 0)
        Button("Move Down") { Task { await model.moveGroup(group, by: 1) } }
            .disabled(index == model.groups.count - 1)
        Divider()
        Button("Delete Group…", role: .destructive) { model.groupPendingDeletion = group }
    }
}
