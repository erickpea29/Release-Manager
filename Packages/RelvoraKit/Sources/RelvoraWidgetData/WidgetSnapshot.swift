import Foundation
import RelvoraCore

/// What the desktop widget shows (ADR 0024). The app writes it to the App Group container it shares with the widget
/// whenever a project's numbers change; the widget reads only this, never the data store.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// Raised when a change would confuse an older widget. A widget reads only the format it knows.
    public static let currentFormat = 1

    public var format: Int
    /// Active projects, in the sidebar's order: each group's, then those outside any group.
    public var projects: [ProjectEntry]

    public init(projects: [ProjectEntry], format: Int = Self.currentFormat) {
        self.format = format
        self.projects = projects
    }

    public func project(_ id: UUID) -> ProjectEntry? {
        projects.first { $0.id == id }
    }

    /// Projects with a version being planned, in the sidebar's order.
    public var projectsWithNextRelease: [ProjectEntry] {
        projects.filter { $0.nextRelease != nil }
    }
}

extension WidgetSnapshot {
    /// One active project.
    public struct ProjectEntry: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public var name: String
        /// An SF Symbol, as in the sidebar.
        public var iconName: String
        public var groupName: String?
        /// The version being planned, if any.
        public var nextRelease: NextRelease?
        /// The newest published release, if any.
        public var lastRelease: LastRelease?

        public init(
            id: UUID, name: String, iconName: String, groupName: String? = nil, nextRelease: NextRelease? = nil,
            lastRelease: LastRelease? = nil
        ) {
            self.id = id
            self.name = name
            self.iconName = iconName
            self.groupName = groupName
            self.nextRelease = nextRelease
            self.lastRelease = lastRelease
        }
    }

    /// The version being planned: its Board's tasks and where it stands.
    public struct NextRelease: Codable, Sendable, Equatable {
        public var version: String
        public var title: String?
        public var status: ReleasePlanStatus
        /// Tasks of the version (on its Board), and how many of them are done.
        public var doneCount: Int
        public var taskCount: Int
        public var plannedDate: Date?

        public init(
            version: String, title: String? = nil, status: ReleasePlanStatus, doneCount: Int, taskCount: Int,
            plannedDate: Date? = nil
        ) {
            self.version = version
            self.title = title
            self.status = status
            self.doneCount = doneCount
            self.taskCount = taskCount
            self.plannedDate = plannedDate
        }

        /// From 0 to 1; `nil` while the version has no tasks.
        public var progress: Double? {
            taskCount == 0 ? nil : Double(min(doneCount, taskCount)) / Double(taskCount)
        }
    }

    public struct LastRelease: Codable, Sendable, Equatable {
        public var version: String
        public var publishedAt: Date?

        public init(version: String, publishedAt: Date?) {
            self.version = version
            self.publishedAt = publishedAt
        }
    }
}

// MARK: Building

extension WidgetSnapshot {
    /// The icon of a project without one, as in the sidebar.
    public static let defaultIconName = "shippingbox"

    /// What the app knows about one project's releases (its Dashboard numbers).
    public struct Progress: Sendable, Equatable {
        public var activePlan: ReleasePlan?
        /// Tasks of the active plan's version, and how many are done.
        public var versionTaskCount: Int
        public var versionDoneCount: Int
        public var lastRelease: ReleaseSnapshot?

        public init(
            activePlan: ReleasePlan?, versionTaskCount: Int, versionDoneCount: Int, lastRelease: ReleaseSnapshot?
        ) {
            self.activePlan = activePlan
            self.versionTaskCount = versionTaskCount
            self.versionDoneCount = versionDoneCount
            self.lastRelease = lastRelease
        }
    }

    /// The snapshot of the active projects, in the sidebar's order. A project whose numbers aren't known yet is listed
    /// with no next or last release.
    public static func make(projects: [Project], groups: [ProjectGroup], progress: [UUID: Progress]) -> WidgetSnapshot {
        let sections = ProjectGrouping.sections(projects.filter { !$0.isArchived }, groups: groups)
        let entries = sections.flatMap { section in
            section.projects.map { project in
                let known = progress[project.id]
                return ProjectEntry(
                    id: project.id, name: project.name, iconName: project.iconName ?? defaultIconName,
                    groupName: section.group?.name,
                    nextRelease: known.flatMap(nextRelease), lastRelease: known?.lastRelease.flatMap(lastRelease))
            }
        }
        return WidgetSnapshot(projects: entries)
    }

    private static func nextRelease(_ progress: Progress) -> NextRelease? {
        guard let plan = progress.activePlan, plan.status.isActive else { return nil }
        return NextRelease(
            version: plan.version, title: plan.title, status: plan.status, doneCount: progress.versionDoneCount,
            taskCount: progress.versionTaskCount, plannedDate: plan.plannedDate)
    }

    private static func lastRelease(_ snapshot: ReleaseSnapshot) -> LastRelease? {
        guard snapshot.state == .published else { return nil }
        return LastRelease(version: snapshot.version, publishedAt: snapshot.publishedAt)
    }
}
