import RelvoraCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var query = ""
    @SceneStorage("showArchivedProjects") private var showArchived = false
    @FocusState private var isListFocused: Bool

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
            Section("Projects") {
                ForEach(ProjectSearch.filter(model.activeProjects, query: query)) { project in
                    row(project)
                }
                if model.hasLoaded && model.activeProjects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                } else if !query.isEmpty && ProjectSearch.filter(model.projects, query: query).isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
            if !model.archivedProjects.isEmpty {
                Section("Archived", isExpanded: query.isEmpty ? $showArchived : .constant(true)) {
                    ForEach(ProjectSearch.filter(model.archivedProjects, query: query)) { project in
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
            Button("New Project", systemImage: "plus") { model.projectEditor = .new }
                .buttonStyle(.borderless)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("New Project (⇧⌘N)")
        }
        // The list, not the search field, has focus when the window opens, as in a system sidebar. AppKit focuses
        // the first text field as the window appears, so this runs just after.
        .task { isListFocused = true }
    }

    private func row(_ project: Project) -> some View {
        Label(project.name, systemImage: project.isArchived ? "archivebox" : (project.iconName ?? "shippingbox"))
            .badge(model.stats[project.id]?.activePlanVersion.map { Text($0) })
            .tag(SidebarItem.project(project.id))
            .contextMenu { ProjectContextMenu(project: project) }
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

/// Edit, archive, and delete: the same menu in the sidebar and the collapsed sidebar.
struct ProjectContextMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        Button("Edit Project…") { model.projectEditor = .edit(project) }
        Button(project.isArchived ? "Unarchive" : "Archive") {
            Task { await model.setArchived(project, !project.isArchived) }
        }
        Divider()
        Button("Delete Project…", role: .destructive) { model.projectPendingDeletion = project }
    }
}
