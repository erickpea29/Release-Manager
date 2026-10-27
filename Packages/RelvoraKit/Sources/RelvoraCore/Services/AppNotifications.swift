import Foundation

/// What Relvora can tell the user about with a macOS notification (ADR 0019). Each kind can be turned off in
/// Settings › Notifications.
public enum NotificationKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case releasePublished
    case plannedForToday
    case updateAvailable
    case claudeAddedTasks
    case ciFinished

    public var id: Self { self }

    public var title: String {
        switch self {
        case .releasePublished: "A release is published"
        case .plannedForToday: "A version is planned for today"
        case .updateAvailable: "A new Relvora is available"
        case .claudeAddedTasks: "Claude added tasks"
        case .ciFinished: "CI finishes"
        }
    }

    public var explanation: String {
        switch self {
        case .releasePublished:
            "When Relvora verifies a publication on GitHub: one made in Relvora, or a draft published on GitHub. "
                + "While Relvora is open, it checks drafts waiting on GitHub every 5 minutes."
        case .plannedForToday:
            "At 9:00 on a version’s planned date, even when Relvora is closed."
        case .updateAvailable:
            "When the daily update check finds a new version, with its build ready to install."
        case .claudeAddedTasks:
            "When a Claude Code session creates tasks (Settings › Claude)."
        case .ciFinished:
            "On an open pull request, or on the latest commit of the branch a version is planned from. While Relvora "
                + "is open, it checks the repositories of versions being planned every 2 minutes."
        }
    }
}

/// Where clicking a notification takes the user.
public enum NotificationTarget: Sendable, Equatable {
    /// A project, on one of its tabs (`WorkspaceTab` raw values: board, releases…).
    case project(UUID, tab: String)
    /// The update sheet.
    case update
}

/// One notification: delivered now, or scheduled for `fireDate`.
public struct NotificationContent: Sendable, Equatable {
    /// Same identifier, same notification: a newer one replaces it, and a scheduled one can be removed.
    public let id: String
    public let kind: NotificationKind
    public let title: String
    public let body: String
    /// Notifications of one project are grouped.
    public let threadID: String
    public let target: NotificationTarget
    public let fireDate: Date?

    public init(
        id: String, kind: NotificationKind, title: String, body: String, threadID: String, target: NotificationTarget,
        fireDate: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.threadID = threadID
        self.target = target
        self.fireDate = fireDate
    }
}

/// The notifications' wording and timing. Pure, so it's tested without macOS's notification center.
public enum AppNotifications {
    /// Scheduled "planned for today" notifications start with this, so they can be found and replaced.
    public static let plannedPrefix = "planned-"
    /// The hour of the planned date at which "planned for today" arrives.
    public static let plannedHour = 9

    public static func published(_ snapshot: ReleaseSnapshot, project: Project) -> NotificationContent {
        let commit = snapshot.effectiveCommitSHA.prefix(7)
        return NotificationContent(
            id: "published-\(snapshot.id.uuidString)", kind: .releasePublished,
            title: "\(project.name) \(snapshot.version) is published",
            body: "GitHub has the release \(snapshot.effectiveTagName), verified at \(commit) in "
                + "\(snapshot.repositoryFullName).",
            threadID: project.id.uuidString, target: .project(project.id, tab: "releases"))
    }

    /// The "planned for today" notification of every active plan with a planned date still ahead.
    public static func plannedForToday(
        _ plans: [ReleasePlan], project: Project, now: Date, calendar: Calendar = .current
    ) -> [NotificationContent] {
        plans.compactMap { plan in
            guard plan.status.isActive, !project.isArchived, let date = plan.plannedDate,
                let fireDate = plannedFireDate(date, now: now, calendar: calendar)
            else { return nil }
            let title = plan.title.map { " (\($0))" } ?? ""
            return NotificationContent(
                id: plannedPrefix + plan.id.uuidString, kind: .plannedForToday,
                title: "\(project.name) \(plan.version) is planned for today",
                body: "Version \(plan.version)\(title) has today as its planned date. Its tasks and checklist are "
                    + "in Relvora.",
                threadID: project.id.uuidString, target: .project(project.id, tab: "releases"), fireDate: fireDate)
        }
    }

    /// 9:00 on the planned day, in the user's calendar; `nil` once that time has passed.
    public static func plannedFireDate(_ plannedDate: Date, now: Date, calendar: Calendar = .current) -> Date? {
        var day = calendar.dateComponents([.year, .month, .day], from: plannedDate)
        day.hour = plannedHour
        guard let fireDate = calendar.date(from: day), fireDate > now else { return nil }
        return fireDate
    }

    public static func updateAvailable(_ version: SemanticVersion, current: SemanticVersion?) -> NotificationContent {
        NotificationContent(
            id: "update-\(version)", kind: .updateAvailable, title: "Relvora \(version) is available",
            body: (current.map { "You have \($0). " } ?? "") + "Click to see what’s new and install it.",
            threadID: "updates", target: .update)
    }

    public static func claudeAddedTasks(
        count: Int, projectID: UUID, projectName: String, version: String?, id: UUID = UUID()
    ) -> NotificationContent {
        let tasks = count == 1 ? "1 task" : "\(count) tasks"
        let place = version.map { "\(projectName) \($0)" } ?? "the Backlog of \(projectName)"
        return NotificationContent(
            id: "claude-\(id.uuidString)", kind: .claudeAddedTasks, title: "Claude added \(tasks)",
            body: "To \(place). They’re labeled “claude”.", threadID: projectID.uuidString,
            target: .project(projectID, tab: version == nil ? "backlog" : "board"))
    }

    /// Published snapshots not seen before: the ones to announce. The first look at a project only remembers what's
    /// there.
    public static func newlyPublished(_ snapshots: [ReleaseSnapshot], known: Set<UUID>?) -> [ReleaseSnapshot] {
        guard let known else { return [] }
        return snapshots.filter { $0.state == .published && !known.contains($0.id) }
    }
}
