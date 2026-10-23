import RelvoraCore
import SwiftUI

/// Every release snapshot across projects, newest first. Snapshots never change after their release, so this is
/// the record of what shipped.
struct ReleaseHistoryView: View {
    /// Which releases the list shows.
    enum Scope: Hashable {
        case all
        case group(UUID)
        case project(UUID)
    }

    @Environment(AppModel.self) private var app
    @State private var scope = Scope.all
    @State private var query = ""

    private var entries: [ReleaseSnapshot] {
        app.releaseHistory
            .filter(isInScope)
            .filter {
                TextSearch.matches(
                    query, fields: [$0.version, $0.tagName, $0.title, $0.repositoryFullName, $0.releaseNotesMarkdown])
            }
            .sorted { Self.date($0) > Self.date($1) }
    }

    private var selected: ReleaseSnapshot? { entries.first { $0.id == app.historySelection } }

    var body: some View {
        @Bindable var app = app
        Group {
            if app.releaseHistory.isEmpty {
                ContentUnavailableView(
                    "No Releases Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Releases appear here when you create a GitHub draft from a release plan, with the notes and "
                            + "tasks as they were.")
                )
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 280)
                    Divider()
                    if let selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Spacing.l) {
                                header(selected)
                                SnapshotDetailView(snapshot: selected, projectName: projectName(selected.projectID))
                            }
                            .padding(Spacing.l)
                            .frame(maxWidth: 860, alignment: .leading)
                            // Centered in wide windows, such as with the sidebar closed.
                            .frame(maxWidth: .infinity)
                        }
                        .id(selected.id)
                    } else {
                        ContentUnavailableView("Select a Release", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .navigationTitle("Release History")
        .task { await app.loadHistory() }
        .onChange(of: entries.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == app.historySelection }) { app.historySelection = ids.first }
        }
        .onAppear { if selected == nil { app.historySelection = entries.first?.id } }
    }

    private var list: some View {
        @Bindable var app = app
        return List(selection: $app.historySelection) {
            ForEach(entries) { snapshot in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(snapshot.version).font(.headline.monospaced()).lineLimit(1)
                        Spacer()
                        RowStatusLabel(snapshot.state, isSelected: snapshot.id == app.historySelection)
                    }
                    Text(projectName(snapshot.projectID) ?? "Deleted project")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(
                        "\(snapshot.repositoryFullName) · "
                            + Self.date(snapshot).formatted(date: .abbreviated, time: .omitted)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, Spacing.xxs)
                .tag(snapshot.id)
                .accessibilityElement(children: .combine)
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: Spacing.xs) {
                TextField("Search releases", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Project", selection: $scope) {
                    Text("All Projects").tag(Scope.all)
                    ForEach(scopeSections) { section in
                        if let group = section.group {
                            Section(group.name) {
                                Text("All of \(group.name)").tag(Scope.group(group.id))
                                ForEach(section.projects) { Text($0.name).tag(Scope.project($0.id)) }
                            }
                        } else if app.groups.isEmpty {
                            ForEach(section.projects) { Text($0.name).tag(Scope.project($0.id)) }
                        } else {
                            Section("Other Projects") {
                                ForEach(section.projects) { Text($0.name).tag(Scope.project($0.id)) }
                            }
                        }
                    }
                }
                .labelsHidden()
            }
            .padding(Spacing.s)
        }
    }

    private func header(_ snapshot: ReleaseSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(snapshot.version).font(.title.bold().monospaced()).textSelection(.enabled)
                SnapshotStateBadge(state: snapshot.state)
                if snapshot.origin == .external {
                    Text("Recorded from GitHub").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let title = snapshot.title { Text(title).font(.title3).foregroundStyle(.secondary) }
            Text(stateExplanation(snapshot))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateExplanation(_ snapshot: ReleaseSnapshot) -> String {
        switch snapshot.state {
        case .pending: "GitHub hasn’t confirmed this draft yet. Open the release plan and check GitHub."
        case .draftCreated: "A draft on GitHub, not yet published."
        case .published: "Published on GitHub, with the tag verified at the recorded commit."
        case .abandoned: "This draft was deleted on GitHub before it was published."
        }
    }

    /// Projects with releases, archived ones included, by group.
    private var scopeSections: [ProjectSection] {
        let ids = Set(app.releaseHistory.map(\.projectID))
        return ProjectGrouping.sections(app.projects.filter { ids.contains($0.id) }, groups: app.groups)
            .filter { !$0.projects.isEmpty }
    }

    private func isInScope(_ snapshot: ReleaseSnapshot) -> Bool {
        switch scope {
        case .all: true
        case .project(let id): snapshot.projectID == id
        case .group(let id): app.projects.contains { $0.id == snapshot.projectID && $0.groupID == id }
        }
    }

    private func projectName(_ id: UUID) -> String? { app.projects.first { $0.id == id }?.name }

    private static func date(_ snapshot: ReleaseSnapshot) -> Date { snapshot.publishedAt ?? snapshot.snapshotCreatedAt }
}
