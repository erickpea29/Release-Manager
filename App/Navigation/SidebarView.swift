import RelvoraCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var query = ""
    @SceneStorage("showArchivedProjects") private var showArchived = false

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
        .searchable(text: $query, placement: .sidebar, prompt: "Search projects")
        .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            Button("New Project", systemImage: "plus") { model.projectEditor = .new }
                .buttonStyle(.borderless)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("New Project (⇧⌘N)")
        }
    }

    private func row(_ project: Project) -> some View {
        Label(project.name, systemImage: project.isArchived ? "archivebox" : (project.iconName ?? "shippingbox"))
            .badge(model.stats[project.id]?.activePlanVersion.map { Text($0) })
            .tag(SidebarItem.project(project.id))
            .contextMenu {
                Button("Edit Project…") { model.projectEditor = .edit(project) }
                Button(project.isArchived ? "Unarchive" : "Archive") {
                    Task { await model.setArchived(project, !project.isArchived) }
                }
                Divider()
                Button("Delete Project…", role: .destructive) { model.projectPendingDeletion = project }
            }
    }
}
