import Foundation

public enum TaskPriority: String, Sendable, CaseIterable, Codable, Comparable {
    case low, medium, high, urgent

    public var title: String { rawValue.capitalized }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum TaskType: String, Sendable, CaseIterable, Codable {
    case feature, improvement, bugFix, documentation, maintenance, other

    public var title: String {
        switch self {
        case .feature: "Feature"
        case .improvement: "Improvement"
        case .bugFix: "Bug fix"
        case .documentation: "Documentation"
        case .maintenance: "Maintenance"
        case .other: "Other"
        }
    }
}

public struct ChecklistItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var isDone: Bool
    public var sortOrder: Double

    public init(id: UUID = UUID(), title: String, isDone: Bool = false, sortOrder: Double) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.sortOrder = sortOrder
    }
}

/// A unit of work on a project's board. Named `ProjectTask` to avoid shadowing Swift's `Task`.
public struct ProjectTask: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public var columnID: UUID
    public var releasePlanID: UUID?
    public var title: String
    /// Markdown notes.
    public var details: String?
    public var priority: TaskPriority
    public var type: TaskType
    public var labels: [String]
    public var checklist: [ChecklistItem]
    public var sortOrder: Double
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        columnID: UUID,
        releasePlanID: UUID? = nil,
        title: String,
        details: String? = nil,
        priority: TaskPriority = .medium,
        type: TaskType = .feature,
        labels: [String] = [],
        checklist: [ChecklistItem] = [],
        sortOrder: Double,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.columnID = columnID
        self.releasePlanID = releasePlanID
        self.title = title
        self.details = details
        self.priority = priority
        self.type = type
        self.labels = Self.normalizedLabels(labels)
        self.checklist = checklist
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }

    /// Trims labels, drops empty ones, and removes case-insensitive duplicates (first spelling wins).
    public static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return
            labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
