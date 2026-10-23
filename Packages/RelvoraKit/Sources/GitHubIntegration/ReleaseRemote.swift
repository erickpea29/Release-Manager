import Foundation
import RelvoraCore

/// The release workflow's GitHub operations, over the REST client.
public struct GitHubReleaseRemote: ReleaseRemote {
    /// Up to 1,000 releases are checked for an existing tag or an unconfirmed draft.
    public static let maxReleasePages = 10

    private let api: GitHubAPIClient

    public init(api: GitHubAPIClient) {
        self.api = api
    }

    public func repository(id: Int64) async throws -> GitHubRepository {
        try await api.repository(id: id)
    }

    public func releases(of repository: GitHubRepository) async throws -> (items: [RemoteRelease], truncated: Bool) {
        try await api.releases(of: repository, maxPages: Self.maxReleasePages)
    }

    public func release(of repository: GitHubRepository, id: Int64) async throws -> RemoteRelease? {
        do {
            return try await api.release(of: repository, id: id)
        } catch .notFound {
            return nil
        }
    }

    public func tagCommitSHA(of repository: GitHubRepository, tag: String) async throws -> String? {
        try await api.tagCommitSHA(of: repository, tag: tag)
    }

    public func createDraftRelease(in repository: GitHubRepository, _ request: DraftReleaseRequest) async
        -> DraftCreationResult
    {
        do {
            return .created(try await api.createDraftRelease(in: repository, request))
        } catch {
            return error.mayHaveReachedGitHub ? .unknown(error) : .rejected(error)
        }
    }

    public func publishRelease(in repository: GitHubRepository, id: Int64) async -> ReleasePublishResult {
        do {
            return .published(try await api.publishRelease(in: repository, id: id))
        } catch {
            return error.mayHaveReachedGitHub ? .unknown(error) : .rejected(error)
        }
    }
}
