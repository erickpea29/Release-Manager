import Foundation

public enum ProjectRules {
    public static let maximumNameLength = 100

    /// Returns the trimmed name, or throws if it is empty or too long.
    public static func validatedName(_ name: String) throws(ValidationError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard trimmed.count <= maximumNameLength else { throw .nameTooLong(maximum: maximumNameLength) }
        return trimmed
    }

    /// Default board for new projects. The last column is the completion column.
    public static let defaultColumnNames = ["Backlog", "To Do", "In Progress", "Review", "Done"]

    public static func defaultColumns(projectID: UUID, now: Date) -> [BoardColumn] {
        let orders = FractionalIndex.renormalized(count: defaultColumnNames.count)
        return zip(defaultColumnNames, orders).map { name, order in
            BoardColumn(
                projectID: projectID,
                name: name,
                sortOrder: order,
                isCompletionColumn: name == defaultColumnNames.last,
                createdAt: now
            )
        }
    }
}

/// Project lifecycle: create, edit, archive, delete.
public struct ProjectService: Sendable {
    private let repository: any ProjectRepository
    private let now: @Sendable () -> Date

    public init(repository: any ProjectRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    /// Creates a validated project with the default board in one transaction.
    /// Throws `ValidationError` for bad input or `PersistenceError` if saving fails.
    public func create(name: String, details: String? = nil) async throws -> Project {
        let timestamp = now()
        let project = Project(
            name: try ProjectRules.validatedName(name),
            details: details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: timestamp
        )
        try await repository.create(
            project,
            columns: ProjectRules.defaultColumns(projectID: project.id, now: timestamp)
        )
        return project
    }

    public func update(_ project: Project, name: String, details: String?) async throws -> Project {
        var updated = project
        updated.name = try ProjectRules.validatedName(name)
        updated.details = details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.updatedAt = now()
        try await repository.update(updated)
        return updated
    }

    public func setArchived(_ project: Project, _ archived: Bool) async throws -> Project {
        guard project.isArchived != archived else { return project }
        var updated = project
        let timestamp = now()
        updated.archivedAt = archived ? timestamp : nil
        updated.updatedAt = timestamp
        try await repository.update(updated)
        return updated
    }

    public func delete(_ projectID: UUID) async throws {
        try await repository.deleteProject(id: projectID)
    }
}
