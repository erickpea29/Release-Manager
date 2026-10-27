import Foundation

/// The version being planned and how far along it is: what "What's the next release of …" answers in Shortcuts and
/// Siri (ADR 0023).
public struct VersionProgress: Sendable, Equatable {
    public let plan: ReleasePlan
    /// The version's tasks.
    public let total: Int
    /// Those of them in the completion column.
    public let done: Int

    /// The project's version being planned; `nil` when there's none.
    public init?(plans: [ReleasePlan], board: BoardState) {
        guard let plan = plans.first(where: \.status.isActive) else { return nil }
        let tasks = board.tasks.filter { VersionScope.isOnBoard($0, activePlanID: plan.id) }
        self.plan = plan
        total = tasks.count
        done = tasks.count { $0.completedAt != nil }
    }

    /// "The next release of Relvora is 0.2.4 (Spotlight). 3 of 8 tasks are done. It’s planned for November 2, 2026."
    public func summary(
        projectName: String, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let title = plan.title.map { " (\($0))" } ?? ""
        let status =
            switch plan.status {
            case .draftCreated: ", with a draft on GitHub"
            case .reconciliationNeeded: ", which needs checking against GitHub"
            default: ""
            }
        let progress =
            switch (done, total) {
            case (_, 0): "It has no tasks yet."
            case (1, 1): "Its only task is done."
            case (total, _): "All \(total) tasks are done."
            default: "\(done) of \(total) \(total == 1 ? "task is" : "tasks are") done."
            }
        var sentences = ["The next release of \(projectName) is \(plan.version)\(title)\(status).", progress]
        if let date = plan.plannedDate {
            let day = date.formatted(
                Date.FormatStyle(
                    date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
            if calendar.isDate(date, inSameDayAs: now) {
                sentences.append("It’s planned for today.")
            } else {
                sentences.append(date > now ? "It’s planned for \(day)." : "It was planned for \(day).")
            }
        }
        return sentences.joined(separator: " ")
    }

    public static func nothingPlanned(projectName: String) -> String {
        "\(projectName) has no version being planned."
    }
}

/// A project as Spotlight and Shortcuts list it.
public struct SearchableProject: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let details: String?
    public let groupName: String?
    /// The version being planned, if any.
    public let version: String?

    public init(id: UUID, name: String, details: String?, groupName: String?, version: String?) {
        self.id = id
        self.name = name
        self.details = details
        self.groupName = groupName
        self.version = version
    }

    /// "Acme · Planning 0.2.4"; empty for a project outside any group with no version being planned.
    public var subtitle: String {
        [groupName, version.map { "Planning \($0)" }].compactMap(\.self).joined(separator: " · ")
    }
}

/// A task as Spotlight and Shortcuts list it: in the version being planned, or in the Backlog.
public struct SearchableTask: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let projectName: String
    public let title: String
    public let notes: String?
    public let labels: [String]
    public let type: TaskType
    public let priority: TaskPriority
    /// Its column, which is its status.
    public let column: String?
    /// The version being planned when the task is in it; `nil` in the Backlog.
    public let version: String?
    public let isDone: Bool

    public init(
        id: UUID, projectID: UUID, projectName: String, title: String, notes: String?, labels: [String],
        type: TaskType, priority: TaskPriority, column: String?, version: String?, isDone: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.notes = notes
        self.labels = labels
        self.type = type
        self.priority = priority
        self.column = column
        self.version = version
        self.isDone = isDone
    }

    /// On the Board (the version being planned) rather than in the Backlog.
    public var isOnBoard: Bool { version != nil }

    /// "Relvora 0.2.4 · In Progress", or "Relvora Backlog · To Do".
    public var subtitle: String {
        let place = version.map { "\(projectName) \($0)" } ?? "\(projectName) Backlog"
        return column.map { "\(place) · \($0)" } ?? place
    }

    /// Every term of `query` is in the title, the notes, a label, or the project's name.
    public func matches(_ query: String) -> Bool {
        TextSearch.matches(query, fields: [title, notes, projectName] + labels)
    }
}

/// One thing Spotlight lists.
public enum SearchableItem: Sendable, Hashable, Identifiable {
    case project(SearchableProject)
    case task(SearchableTask)

    /// What a Spotlight result opens.
    public enum Target: Sendable, Hashable {
        case project(UUID)
        case task(UUID)
    }

    public var target: Target {
        switch self {
        case .project(let project): .project(project.id)
        case .task(let task): .task(task.id)
        }
    }

    /// Spotlight's identifier: "project-<UUID>" or "task-<UUID>".
    public var id: String { Self.identifier(target) }

    public static func identifier(_ target: Target) -> String {
        switch target {
        case .project(let id): "project-\(id.uuidString)"
        case .task(let id): "task-\(id.uuidString)"
        }
    }

    /// The project or task a Spotlight identifier refers to.
    public static func target(of identifier: String) -> Target? {
        let parts = identifier.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        return switch parts[0] {
        case "project": .project(id)
        case "task": .task(id)
        default: nil
        }
    }
}

/// What Relvora shows in Spotlight, and offers in Shortcuts (ADR 0023). Pure, so it's tested without Spotlight.
public enum SystemSearch {
    /// Nothing for an archived project.
    public static func project(_ project: Project, groupName: String?, plans: [ReleasePlan]) -> SearchableProject? {
        guard !project.isArchived else { return nil }
        return SearchableProject(
            id: project.id, name: project.name, details: project.details, groupName: groupName,
            version: plans.first(where: \.status.isActive)?.version)
    }

    /// The tasks worth finding: the version being planned's, done or not, and the Backlog's. Finished tasks outside the
    /// version, such as those of past releases, stay out. Nothing for an archived project. In Board order.
    public static func tasks(of project: Project, board: BoardState, plans: [ReleasePlan]) -> [SearchableTask] {
        guard !project.isArchived else { return [] }
        let plan = plans.first(where: \.status.isActive)
        let columns = board.orderedColumns
        return columns.flatMap { board.tasks(in: $0.id) }
            .filter {
                VersionScope.isOnBoard($0, activePlanID: plan?.id)
                    || VersionScope.isInBacklog($0, activePlanID: plan?.id)
            }
            .map { task in
                SearchableTask(
                    id: task.id, projectID: project.id, projectName: project.name, title: task.title,
                    notes: task.details, labels: task.labels, type: task.type, priority: task.priority,
                    column: board.column(task.columnID)?.name,
                    version: VersionScope.isOnBoard(task, activePlanID: plan?.id) ? plan?.version : nil,
                    isDone: task.completedAt != nil)
            }
    }

    /// Everything one project puts in Spotlight: itself and its tasks.
    public static func items(_ project: Project, groupName: String?, board: BoardState, plans: [ReleasePlan])
        -> [SearchableItem]
    {
        guard let searchable = self.project(project, groupName: groupName, plans: plans) else { return [] }
        return [.project(searchable)] + tasks(of: project, board: board, plans: plans).map(SearchableItem.task)
    }

    /// What Spotlight needs to go from `indexed` to `current`: the items that are new or changed, and the identifiers
    /// of those that are gone (deleted, archived, finished in a past version).
    public static func changes(from indexed: [String: SearchableItem], to current: [SearchableItem]) -> (
        index: [SearchableItem], remove: [String]
    ) {
        let currentIDs = Set(current.map(\.id))
        return (
            current.filter { indexed[$0.id] != $0 },
            indexed.keys.filter { !currentIDs.contains($0) }.sorted()
        )
    }
}
