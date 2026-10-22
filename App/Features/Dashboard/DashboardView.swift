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
                    if !attention.isEmpty {
                        section("Needs Attention") {
                            ForEach(attention, id: \.plan.id) { item in
                                AttentionRow(project: item.project, plan: item.plan) {
                                    model.openProject(item.project.id, tab: .releases)
                                }
                            }
                        }
                    }
                    section("Projects") {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.m)], spacing: Spacing.m
                        ) {
                            ForEach(model.activeProjects) { project in
                                Button {
                                    openProject(project.id)
                                } label: {
                                    ProjectSummaryCard(
                                        project: project, stats: model.stats[project.id] ?? ProjectStats())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Projects")
                    }
                    if !recentReleases.isEmpty {
                        section("Recent Releases") {
                            VStack(spacing: 0) {
                                ForEach(recentReleases) { snapshot in
                                    RecentReleaseRow(snapshot: snapshot, projectName: projectName(snapshot.projectID)) {
                                        model.showInHistory(snapshot.id)
                                    }
                                    if snapshot.id != recentReleases.last?.id { Divider() }
                                }
                            }
                            .panel(padding: Spacing.s)
                        }
                    }
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { await model.loadHistory() }
        }
    }

    /// Releases waiting on GitHub or on the user, across active projects.
    private var attention: [(project: Project, plan: ReleasePlan)] {
        model.activeProjects.compactMap { project in
            guard let plan = model.stats[project.id]?.activePlan,
                plan.status == .draftCreated || plan.status == .reconciliationNeeded
            else { return nil }
            return (project, plan)
        }
    }

    private var recentReleases: [ReleaseSnapshot] {
        Array(
            model.releaseHistory.filter { $0.state == .published }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(5))
    }

    private func projectName(_ id: UUID) -> String { model.projects.first { $0.id == id }?.name ?? "Deleted project" }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}

private struct AttentionRow: View {
    let project: Project
    let plan: ReleasePlan
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.s) {
                StatusBadge(status: plan.status)
                Text("\(project.name) \(plan.version)").font(.headline)
                Text(
                    plan.status == .draftCreated
                        ? "Publish the draft on GitHub, then check publication."
                        : "Check GitHub to find out what happened."
                )
                .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .panel(padding: Spacing.s)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the release plan")
    }
}

private struct RecentReleaseRow: View {
    let snapshot: ReleaseSnapshot
    let projectName: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(snapshot.version).font(.body.monospaced().weight(.semibold))
                Text(projectName).foregroundStyle(.secondary)
                Spacer()
                if let date = snapshot.publishedAt {
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.xxs)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the release in Release History")
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
