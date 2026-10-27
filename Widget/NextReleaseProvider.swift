import Foundation
import RelvoraWidgetData
import WidgetKit

struct NextReleaseEntry: TimelineEntry {
    let date: Date
    /// `nil` until Relvora has written one, and always in a copy that can't share it (ad-hoc signed).
    let snapshot: WidgetSnapshot?
    /// The project chosen in the widget's settings; `nil` for every project.
    let projectID: UUID?
    /// Shown blurred: the widget gallery and the moment before the first timeline. Never real data.
    var isPlaceholder = false

    /// A made-up project, only ever shown blurred.
    static let placeholder: NextReleaseEntry = {
        let id = UUID()
        let project = WidgetSnapshot.ProjectEntry(
            id: id, name: "Project", iconName: WidgetSnapshot.defaultIconName,
            nextRelease: .init(version: "1.0.0", status: .planned, doneCount: 5, taskCount: 8))
        return NextReleaseEntry(
            date: .now, snapshot: WidgetSnapshot(projects: [project]), projectID: nil, isPlaceholder: true)
    }()
}

struct NextReleaseProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NextReleaseEntry {
        .placeholder
    }

    func snapshot(for configuration: ProjectWidgetIntent, in context: Context) async -> NextReleaseEntry {
        let entry = entry(for: configuration)
        // The gallery shows the user's own projects when there are some, and a blurred example otherwise.
        if context.isPreview, entry.snapshot?.projects.isEmpty ?? true { return .placeholder }
        return entry
    }

    /// Relvora reloads the widget whenever the numbers change. Midnight refreshes "Today" and late planned dates.
    func timeline(for configuration: ProjectWidgetIntent, in context: Context) async -> Timeline<NextReleaseEntry> {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return Timeline(entries: [entry(for: configuration)], policy: .after(tomorrow))
    }

    private func entry(for configuration: ProjectWidgetIntent) -> NextReleaseEntry {
        NextReleaseEntry(
            date: .now, snapshot: WidgetSnapshotStore.shared()?.read(), projectID: configuration.project?.id)
    }
}
