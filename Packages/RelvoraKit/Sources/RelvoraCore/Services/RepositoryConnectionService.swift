import Foundation

/// Links GitHub repositories to projects and keeps their metadata current after each sync.
public struct RepositoryConnectionService: Sendable {
    private let repository: any RepositoryConnectionRepository
    private let now: @Sendable () -> Date

    public init(repository: any RepositoryConnectionRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    public func connections(projectID: UUID) async throws -> [RepositoryConnection] {
        try await repository.connections(projectID: projectID)
    }

    public func connect(_ remote: GitHubRepository, to projectID: UUID) async throws -> RepositoryConnection {
        let existing = try await repository.connections(projectID: projectID)
        guard !existing.contains(where: { $0.githubRepositoryID == remote.id }) else {
            throw ValidationError.repositoryAlreadyConnected(remote.fullName)
        }
        let connection = RepositoryConnection(
            projectID: projectID,
            githubRepositoryID: remote.id,
            owner: remote.owner,
            name: remote.name,
            defaultBranch: remote.defaultBranch,
            htmlURL: remote.htmlURL,
            isPrivate: remote.isPrivate,
            createdAt: now()
        )
        try await repository.save(connection)
        return connection
    }

    /// Records a successful sync: refreshes owner, name, branch, and URL (renames and transfers keep the ID).
    public func recordSync(_ connection: RepositoryConnection, remote: GitHubRepository, at date: Date) async throws
        -> RepositoryConnection
    {
        var updated = connection
        updated.owner = remote.owner
        updated.name = remote.name
        updated.defaultBranch = remote.defaultBranch
        updated.htmlURL = remote.htmlURL
        updated.isPrivate = remote.isPrivate
        updated.lastSyncedAt = date
        updated.updatedAt = now()
        try await repository.save(updated)
        return updated
    }

    public func disconnect(_ connection: RepositoryConnection) async throws {
        try await repository.deleteConnection(id: connection.id)
    }
}
