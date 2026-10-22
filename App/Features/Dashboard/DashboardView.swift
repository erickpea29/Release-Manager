import RelvoraCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let openProject: (UUID) -> Void

    var body: some View {
        if model.hasLoaded && model.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "shippingbox")
            } description: {
                Text("Create a project to plan its releases.")
            } actions: {
                Button("New Project") { model.isPresentingNewProject = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Dashboard")
                        .font(.largeTitle.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(model.projects) { project in
                            Button {
                                openProject(project.id)
                            } label: {
                                ProjectSummaryCard(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ProjectSummaryCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(project.name, systemImage: project.iconName ?? "shippingbox")
                .font(.headline)
            Text(project.details ?? "No description")
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Text("Created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project")
    }
}
