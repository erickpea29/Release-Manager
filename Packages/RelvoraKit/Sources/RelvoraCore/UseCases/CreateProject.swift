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

/// Creates a validated project with the default board in one transaction.
public struct CreateProject: Sendable {
    private let repository: any ProjectRepository
    private let now: @Sendable () -> Date

    public init(repository: any ProjectRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    /// Throws `ValidationError` for bad input or `PersistenceError` if saving fails.
    public func callAsFunction(name: String, details: String? = nil) async throws -> Project {
        let timestamp = now()
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            name: try ProjectRules.validatedName(name),
            details: trimmedDetails?.isEmpty == false ? trimmedDetails : nil,
            createdAt: timestamp
        )
        try await repository.create(
            project, columns: ProjectRules.defaultColumns(projectID: project.id, now: timestamp))
        return project
    }
}
