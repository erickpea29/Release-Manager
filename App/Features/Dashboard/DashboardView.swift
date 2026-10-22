import RelvoraCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let openProject: (UUID) -> Void

    var body: some View {
        if model.hasLoaded && model.activeProjects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "shippingbox")
            } description: {
                Text(
                    model.archivedProjects.isEmpty
                        ? "Create a project to plan its releases."
                        : "All projects are archived. Create a new one or unarchive one from the sidebar.")
            } actions: {
                Button("New Project") { model.projectEditor = .new }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Dashboard")
                        .font(.largeTitle.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.m)], spacing: Spacing.m) {
                        ForEach(model.activeProjects) { project in
                            Button {
                                openProject(project.id)
                            } label: {
                                ProjectSummaryCard(project: project, stats: model.stats[project.id] ?? ProjectStats())
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
    let stats: ProjectStats

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Label(project.name, systemImage: project.iconName ?? "shippingbox")
                    .font(.headline)
                Spacer()
                if let version = stats.activePlanVersion {
                    Text("Next: \(version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text(project.details ?? "No description")
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            if let progress = stats.progress {
                ProgressView(value: progress)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(stats.completedCount) of \(stats.taskCount) tasks done")
                Text("\(stats.completedCount) of \(stats.taskCount) tasks done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No tasks yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let release = stats.lastRelease, let date = release.publishedAt {
                Label(
                    "Released \(release.version) \(date.formatted(.relative(presentation: .named)))",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project")
    }
}
