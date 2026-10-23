import Foundation

public struct Project: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var details: String?
    public var iconName: String?
    public var accentColor: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public var isArchived: Bool { archivedAt != nil }

    /// Up to two letters for places too narrow for the name, such as the collapsed sidebar: the first letter of each
    /// of the first two words ("Website Redesign" → "WR").
    public var initials: String {
        let words = name.split { $0.isWhitespace || $0 == "-" || $0 == "_" }
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    public init(
        id: UUID = UUID(),
        name: String,
        details: String? = nil,
        iconName: String? = nil,
        accentColor: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.iconName = iconName
        self.accentColor = accentColor
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.archivedAt = archivedAt
    }
}

public struct BoardColumn: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public var name: String
    public var sortOrder: Double
    /// Tasks in this column count as complete. Exactly one per project.
    public var isCompletionColumn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        sortOrder: Double,
        isCompletionColumn: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.sortOrder = sortOrder
        self.isCompletionColumn = isCompletionColumn
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
