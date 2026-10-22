import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Overview") {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.dashboard)
                Label("Release History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
            }
            Section("Projects") {
                ForEach(model.projects) { project in
                    Label(project.name, systemImage: project.iconName ?? "shippingbox")
                        .tag(SidebarItem.project(project.id))
                }
                if model.hasLoaded && model.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .safeAreaInset(edge: .bottom) {
            Button("New Project", systemImage: "plus") { model.isPresentingNewProject = true }
                .buttonStyle(.borderless)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("New Project (⇧⌘N)")
        }
    }
}
