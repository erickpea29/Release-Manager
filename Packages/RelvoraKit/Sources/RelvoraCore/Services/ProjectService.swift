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

    /// Default board for new projects. The last column is the completion column. There is no Backlog column: the
    /// Backlog is its own tab, holding every task outside the version being planned (`VersionScope`).
    public static let defaultColumnNames = ["To Do", "In Progress", "Review", "Done"]

    public static var defaultTemplate: [ColumnTemplate] {
        defaultColumnNames.map { ColumnTemplate(name: $0, isCompletion: $0 == defaultColumnNames.last) }
    }

    /// The Backlog is its own tab, so no column may be named “Backlog” (in any case).
    public static func isBacklogName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Backlog") == .orderedSame
    }

    /// A template from before the Backlog tab, without its Backlog column. Saved settings and older backups have one.
    public static func withoutBacklog(_ template: [ColumnTemplate]) -> [ColumnTemplate] {
        template.filter { !isBacklogName($0.name) }
    }

    public static func defaultColumns(projectID: UUID, now: Date) -> [BoardColumn] {
        columns(from: defaultTemplate, projectID: projectID, now: now)
    }

    public static func columns(from template: [ColumnTemplate], projectID: UUID, now: Date) -> [BoardColumn] {
        let orders = FractionalIndex.renormalized(count: template.count)
        return zip(template, orders).map { column, order in
            BoardColumn(
                projectID: projectID, name: column.name, sortOrder: order, isCompletionColumn: column.isCompletion,
                createdAt: now)
        }
    }

    /// The board template for new projects (Settings › Board): at least one column, exactly one completion
    /// column, valid names that differ ignoring case.
    public static func validatedTemplate(_ template: [ColumnTemplate]) throws(ValidationError) -> [ColumnTemplate] {
        guard !template.isEmpty else { throw .cannotDeleteLastColumn }
        var seen = Set<String>()
        var result: [ColumnTemplate] = []
        for column in template {
            let name = try BoardPlanner.validatedColumnName(column.name)
            guard !isBacklogName(name) else { throw .reservedColumnName(name) }
            guard seen.insert(name.lowercased()).inserted else { throw .duplicateColumnName(name) }
            result.append(ColumnTemplate(name: name, isCompletion: column.isCompletion))
        }
        guard result.filter(\.isCompletion).count == 1 else { throw .needsOneCompletionColumn }
        return result
    }
}

/// A column of the board new projects start with.
public struct ColumnTemplate: Sendable, Hashable, Codable {
    public var name: String
    public var isCompletion: Bool

    public init(name: String, isCompletion: Bool) {
        self.name = name
        self.isCompletion = isCompletion
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

    /// Creates a validated project and its board (the given template, else the default) in one transaction, in
    /// `groupID` if given. Throws `ValidationError` for bad input or `PersistenceError` if saving fails.
    public func create(
        name: String, details: String? = nil, columns template: [ColumnTemplate]? = nil, groupID: UUID? = nil
    ) async throws -> Project {
        let timestamp = now()
        let project = Project(
            name: try ProjectRules.validatedName(name),
            details: details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            createdAt: timestamp,
            groupID: groupID
        )
        let template = try template.map(ProjectRules.validatedTemplate) ?? ProjectRules.defaultTemplate
        try await repository.create(
            project, columns: ProjectRules.columns(from: template, projectID: project.id, now: timestamp))
        return project
    }

    /// Saves a new name and description, with any other change already made to `project`, such as its group.
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

    /// Lists the project under `groupID`, or outside any group.
    public func setGroup(_ project: Project, _ groupID: UUID?) async throws -> Project {
        guard project.groupID != groupID else { return project }
        var updated = project
        updated.groupID = groupID
        updated.updatedAt = now()
        try await repository.update(updated)
        return updated
    }

    public func delete(_ projectID: UUID) async throws {
        try await repository.deleteProject(id: projectID)
    }
}
