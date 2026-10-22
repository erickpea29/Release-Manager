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
    public static func filter(_ projects: [Project], query: String) -> [Project] {
        projects.filter { TextSearch.matches(query, fields: [$0.name, $0.details]) }
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
