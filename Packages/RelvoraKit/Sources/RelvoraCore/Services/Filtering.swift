import Foundation

public enum TextSearch {
    /// True when every whitespace-separated term occurs in at least one field, ignoring case and diacritics.
    /// An empty query matches everything.
    public static func matches(_ query: String, fields: [String?]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = fields.compactMap(\.self)
        return terms.allSatisfy { term in
            haystack.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

public enum ProjectSearch {
    /// Matches a project's name and description, and the name of its group among `groups`.
    public static func filter(_ projects: [Project], query: String, groups: [ProjectGroup] = []) -> [Project] {
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        return projects.filter { project in
            TextSearch.matches(
                query, fields: [project.name, project.details, project.groupID.flatMap { groupNames[$0] }])
        }
    }
}

/// The Board and the Backlog. The Board holds the version being planned, like a sprint; the Backlog holds every
/// unfinished task outside it. A task's release plan decides where it is; its column is its status in either.
public enum VersionScope {
    /// On the Board: the tasks of the version being planned. Nothing when no version is planned.
    public static func isOnBoard(_ task: ProjectTask, activePlanID: UUID?) -> Bool {
        activePlanID != nil && task.releasePlanID == activePlanID
    }

    /// In the Backlog: unfinished tasks outside the version being planned, including any a released or cancelled
    /// version left unfinished.
    public static func isInBacklog(_ task: ProjectTask, activePlanID: UUID?) -> Bool {
        task.completedAt == nil && !isOnBoard(task, activePlanID: activePlanID)
    }

    /// Finished outside the version being planned and not part of a published release (`publishedPlanIDs`), so
    /// neither the Board nor the release history shows it.
    public static func isDoneOutsideVersion(
        _ task: ProjectTask, activePlanID: UUID?, publishedPlanIDs: Set<UUID>
    ) -> Bool {
        guard task.completedAt != nil, !isOnBoard(task, activePlanID: activePlanID) else { return false }
        return task.releasePlanID.map { !publishedPlanIDs.contains($0) } ?? true
    }

    /// Backlog order: most urgent first, then oldest first.
    public static func backlogOrder(_ lhs: ProjectTask, _ rhs: ProjectTask) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.createdAt < rhs.createdAt
    }
}

/// Board filter. Empty sets mean "any".
public struct TaskFilter: Sendable, Equatable {
    public enum Release: Sendable, Hashable {
        case any
        case unassigned
        case plan(UUID)
    }

    public var text: String
    public var priorities: Set<TaskPriority>
    public var types: Set<TaskType>
    /// Compared case-insensitively.
    public var labels: Set<String>
    public var release: Release
    public var hideCompleted: Bool

    public init(
        text: String = "",
        priorities: Set<TaskPriority> = [],
        types: Set<TaskType> = [],
        labels: Set<String> = [],
        release: Release = .any,
        hideCompleted: Bool = false
    ) {
        self.text = text
        self.priorities = priorities
        self.types = types
        self.labels = labels
        self.release = release
        self.hideCompleted = hideCompleted
    }

    public var isActive: Bool { self != TaskFilter() }

    public func matches(_ task: ProjectTask) -> Bool {
        guard priorities.isEmpty || priorities.contains(task.priority) else { return false }
        guard types.isEmpty || types.contains(task.type) else { return false }
        if !labels.isEmpty {
            let taskLabels = Set(task.labels.map { $0.lowercased() })
            guard !taskLabels.isDisjoint(with: labels.map { $0.lowercased() }) else { return false }
        }
        switch release {
        case .any: break
        case .unassigned: guard task.releasePlanID == nil else { return false }
        case .plan(let id): guard task.releasePlanID == id else { return false }
        }
        if hideCompleted && task.completedAt != nil { return false }
        return TextSearch.matches(text, fields: [task.title, task.details] + task.labels)
    }
}
