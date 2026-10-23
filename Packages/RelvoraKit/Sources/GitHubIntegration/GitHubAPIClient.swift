import Foundation
import RelvoraCore

/// Typed GitHub REST client for the signed-in user. Its only write is creating a draft release.
///
/// - Sends `Authorization`, `Accept: application/vnd.github+json`, and the pinned `X-GitHub-Api-Version`.
/// - Follows `Link: rel="next"` pagination up to a page limit, and only to the API host (the token never
///   goes anywhere else).
/// - Retries reads twice on transient failures (5xx, timeouts, dropped connections) with backoff.
/// - Repeats any request once after a short `Retry-After` and once after a 401 with a refreshed token: GitHub
///   rejects those before acting. A write that fails in a way GitHub may have acted on is never repeated.
public struct GitHubAPIClient: Sendable {
    public typealias Sleeper = @Sendable (_ seconds: Double) async throws -> Void

    private let configuration: GitHubConfiguration
    private let session: GitHubSession
    private let transport: any HTTPTransport
    private let sleep: Sleeper

    public init(
        configuration: GitHubConfiguration,
        session: GitHubSession,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.configuration = configuration
        self.session = session
        self.transport = transport
        self.sleep = sleep
    }

    // MARK: Endpoints

    public func currentUser() async throws(GitHubError) -> GitHubAccount {
        try await get(UserDTO.self, path: "user").account
    }

    /// Every repository the user can reach through the Relvora app's installations.
    public func installationRepositories(maxPagesPerInstallation: Int = 10) async throws(GitHubError)
        -> [GitHubRepository]
    {
        let installations = try await get(InstallationsDTO.self, path: "user/installations").installations
        var repositories: [GitHubRepository] = []
        for installation in installations {
            var next: URL? = url("user/installations/\(installation.id)/repositories", [("per_page", "100")])
            var pages = 0
            while let page = next, pages < maxPagesPerInstallation {
                let (body, response) = try await send(InstallationRepositoriesDTO.self, url: page)
                repositories += body.repositories.map(\.model)
                next = sameHost(LinkHeader.next(in: response.value(forHTTPHeaderField: "Link")))
                pages += 1
            }
        }
        var seen = Set<Int64>()
        return repositories.filter { seen.insert($0.id).inserted }.sorted {
            $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending
        }
    }

    /// Looks a repository up by its stable ID, so renames and transfers are picked up.
    public func repository(id: Int64) async throws(GitHubError) -> GitHubRepository {
        try await get(RepositoryDTO.self, path: "repositories/\(id)").model
    }

    public func releases(of repository: GitHubRepository, maxPages: Int = 3) async throws(GitHubError)
        -> (items: [RemoteRelease], truncated: Bool)
    {
        let result = try await paged(ReleaseDTO.self, path: "repos/\(repository.fullName)/releases", maxPages: maxPages)
        return (result.items.map(\.model), result.truncated)
    }

    public func tags(of repository: GitHubRepository, maxPages: Int = 3) async throws(GitHubError)
        -> (items: [RemoteTag], truncated: Bool)
    {
        let result = try await paged(TagDTO.self, path: "repos/\(repository.fullName)/tags", maxPages: maxPages)
        return (result.items.map(\.model), result.truncated)
    }

    /// Commits reachable from `head` but not from `base`, oldest first.
    public func compare(_ repository: GitHubRepository, base: String, head: String, maxPages: Int = 3)
        async throws(GitHubError) -> (commits: [RemoteCommit], totalCommits: Int, htmlURL: URL?)
    {
        var next: URL? = url("repos/\(repository.fullName)/compare/\(base)...\(head)", [("per_page", "100")])
        var commits: [RemoteCommit] = []
        var total = 0
        var htmlURL: URL?
        var pages = 0
        while let page = next, pages < maxPages {
            let (body, response) = try await send(CompareDTO.self, url: page)
            commits += body.commits.map(\.model)
            total = body.totalCommits
            htmlURL = htmlURL ?? body.htmlUrl
            next = sameHost(LinkHeader.next(in: response.value(forHTTPHeaderField: "Link")))
            pages += 1
        }
        return (commits, total, htmlURL)
    }

    /// The latest commits on `branch`, newest first.
    public func commits(of repository: GitHubRepository, branch: String, limit: Int = 100) async throws(GitHubError)
        -> [RemoteCommit]
    {
        let items = try await get(
            [CommitDTO].self, path: "repos/\(repository.fullName)/commits",
            query: [("sha", branch), ("per_page", String(min(limit, 100)))])
        return items.map(\.model)
    }

    /// One commit by SHA (short or full), branch, or tag; returns the full SHA.
    public func commit(of repository: GitHubRepository, ref: String) async throws(GitHubError) -> RemoteCommit {
        try await get(CommitDTO.self, path: "repos/\(repository.fullName)/commits/\(ref)").model
    }

    public func branches(of repository: GitHubRepository, maxPages: Int = 3) async throws(GitHubError)
        -> (items: [RemoteBranch], truncated: Bool)
    {
        let result = try await paged(BranchDTO.self, path: "repos/\(repository.fullName)/branches", maxPages: maxPages)
        return (result.items.map(\.model), result.truncated)
    }

    /// A release by ID, drafts included. Throws `notFound` when it was deleted.
    public func release(of repository: GitHubRepository, id: Int64) async throws(GitHubError) -> RemoteRelease {
        try await get(ReleaseDTO.self, path: "repos/\(repository.fullName)/releases/\(id)").model
    }

    /// The commit a tag points at, following annotated tags; `nil` when the tag doesn't exist.
    public func tagCommitSHA(of repository: GitHubRepository, tag: String) async throws(GitHubError) -> String? {
        var object: GitObjectDTO
        do {
            object = try await get(GitRefDTO.self, path: "repos/\(repository.fullName)/git/ref/tags/\(tag)").object
        } catch .notFound {
            return nil
        }
        // An annotated tag points at a tag object, which may point at another tag.
        for _ in 0..<4 where object.type == "tag" {
            object = try await get(GitTagDTO.self, path: "repos/\(repository.fullName)/git/tags/\(object.sha)").object
        }
        return object.type == "commit" ? object.sha : nil
    }

    /// Creates a **draft** release. Sent once: on a timeout, dropped connection, or server error the outcome is
    /// unknown and the caller must read GitHub before trying again (GitHub accepts duplicate drafts for one tag).
    public func createDraftRelease(in repository: GitHubRepository, _ request: DraftReleaseRequest)
        async throws(GitHubError) -> RemoteRelease
    {
        let body = CreateReleaseDTO(
            tagName: request.tagName, targetCommitish: request.targetCommitSHA, name: request.name,
            body: request.body, draft: true, prerelease: request.isPrerelease, generateReleaseNotes: false)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw .invalidResponse("Request encoding failed")
        }
        return try await send(
            ReleaseDTO.self, url: url("repos/\(repository.fullName)/releases"), method: "POST", body: data
        ).body.model
    }

    /// Publishes a draft release by setting `draft` to false; nothing else about it changes. GitHub creates the tag at
    /// the draft's target commit, unless the tag already exists. Sent once, like every write. Publishing a release
    /// that is already published changes nothing, so after an unknown outcome it is safe to read GitHub and retry.
    public func publishRelease(in repository: GitHubRepository, id: Int64) async throws(GitHubError) -> RemoteRelease {
        try await send(
            ReleaseDTO.self, url: url("repos/\(repository.fullName)/releases/\(id)"), method: "PATCH",
            body: Data(#"{"draft":false}"#.utf8)
        ).body.model
    }

    /// Pull requests that contain `sha`.
    public func pullRequests(of repository: GitHubRepository, containing sha: String) async throws(GitHubError)
        -> [(pullRequest: RemotePullRequest, baseRef: String?)]
    {
        try await get([PullRequestDTO].self, path: "repos/\(repository.fullName)/commits/\(sha)/pulls")
            .map { ($0.model, $0.base?.ref) }
    }

    // MARK: Request pipeline

    private func url(_ path: String, _ query: [(String, String)] = []) -> URL {
        var components = URLComponents(
            url: configuration.apiBaseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return components.url!
    }

    /// Pagination links are followed only on the API host, so the token is never sent anywhere else.
    private func sameHost(_ link: URL?) -> URL? {
        guard let link, link.host() == configuration.apiBaseURL.host(), link.scheme == "https" else { return nil }
        return link
    }

    private func get<Body: Decodable>(_ type: Body.Type, path: String, query: [(String, String)] = [])
        async throws(GitHubError) -> Body
    {
        try await send(type, url: url(path, query)).body
    }

    private func paged<Item: Decodable>(_ type: Item.Type, path: String, maxPages: Int) async throws(GitHubError)
        -> (items: [Item], truncated: Bool)
    {
        var next: URL? = url(path, [("per_page", "100")])
        var items: [Item] = []
        var pages = 0
        while let page = next, pages < maxPages {
            let (body, response) = try await send([Item].self, url: page)
            items += body
            next = sameHost(LinkHeader.next(in: response.value(forHTTPHeaderField: "Link")))
            pages += 1
        }
        return (items, next != nil)
    }

    private func send<Body: Decodable>(
        _ type: Body.Type, url: URL, method: String = "GET", body: Data? = nil
    ) async throws(GitHubError) -> (body: Body, response: HTTPURLResponse) {
        let isRead = method == "GET"
        var token = try await session.accessToken()
        var refreshedAfterUnauthorized = false
        var attempt = 0
        while true {
            attempt += 1
            let outcome = await perform(url: url, method: method, body: body, token: token)
            switch outcome {
            case .success(let data, let response):
                do {
                    return (try Self.decoder.decode(Body.self, from: data), response)
                } catch {
                    Log.github.error(
                        "Decoding failed for \(url.path(), privacy: .private): \(String(describing: error), privacy: .private)"
                    )
                    throw .invalidResponse("Unexpected response format")
                }
            case .failure(.reauthorizationRequired) where !refreshedAfterUnauthorized:
                refreshedAfterUnauthorized = true
                token = try await session.tokenAfterUnauthorized(rejected: token)
            case .failure(.rateLimited(let resetAt)) where attempt == 1 && (resetAt?.timeIntervalSinceNow ?? 60) <= 5:
                try? await sleep(max(resetAt?.timeIntervalSinceNow ?? 1, 1))
            case .failure(let error) where isRead && error.isTransient && attempt <= 2:
                try? await sleep(Double(attempt) * 0.5)
            case .failure(let error):
                Log.github.error(
                    "\(method, privacy: .public) \(url.path(), privacy: .private) failed: \(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }
    }

    private enum Outcome {
        case success(Data, HTTPURLResponse)
        case failure(GitHubError)
    }

    private func perform(url: URL, method: String, body: Data?, token: Secret) async -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await transport.send(request)
            if let error = GitHubError.classify(response, body: data) { return .failure(error) }
            return .success(data, response)
        } catch let error as URLError {
            return .failure(GitHubError.from(error))
        } catch {
            return .failure(.invalidResponse("Transport failure"))
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - DTOs (internal; mapped to RelvoraCore values)

struct AccountDTO: Decodable {
    let login: String
}

struct UserDTO: Decodable {
    let id: Int64
    let login: String
    let name: String?
    let htmlUrl: URL

    var account: GitHubAccount { GitHubAccount(id: id, login: login, name: name, htmlURL: htmlUrl) }
}

struct InstallationsDTO: Decodable {
    struct Installation: Decodable {
        let id: Int64
    }
    let installations: [Installation]
}

struct InstallationRepositoriesDTO: Decodable {
    let repositories: [RepositoryDTO]
}

struct RepositoryDTO: Decodable {
    let id: Int64
    let name: String
    let owner: AccountDTO
    let `private`: Bool
    let defaultBranch: String?
    let htmlUrl: URL
    let description: String?

    var model: GitHubRepository {
        GitHubRepository(
            id: id, owner: owner.login, name: name, defaultBranch: defaultBranch, htmlURL: htmlUrl,
            isPrivate: `private`, description: description)
    }
}

struct ReleaseDTO: Decodable {
    let id: Int64
    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let createdAt: Date
    let publishedAt: Date?
    let targetCommitish: String
    let htmlUrl: URL
    let body: String?

    var model: RemoteRelease {
        RemoteRelease(
            id: id, tagName: tagName, name: name?.isEmpty == true ? nil : name, isDraft: draft,
            isPrerelease: prerelease, createdAt: createdAt, publishedAt: publishedAt,
            targetCommitish: targetCommitish, htmlURL: htmlUrl, body: body)
    }
}

struct TagDTO: Decodable {
    struct Commit: Decodable {
        let sha: String
    }
    let name: String
    let commit: Commit

    var model: RemoteTag { RemoteTag(name: name, commitSHA: commit.sha) }
}

struct CommitDTO: Decodable {
    struct Detail: Decodable {
        struct Author: Decodable {
            let name: String?
            let date: Date?
        }
        let message: String
        let author: Author?
    }
    let sha: String
    let htmlUrl: URL
    let commit: Detail
    let author: AccountDTO?

    var model: RemoteCommit {
        RemoteCommit(
            sha: sha, message: commit.message, authorName: commit.author?.name, authorLogin: author?.login,
            date: commit.author?.date, htmlURL: htmlUrl)
    }
}

struct CompareDTO: Decodable {
    let totalCommits: Int
    let commits: [CommitDTO]
    let htmlUrl: URL?
}

struct BranchDTO: Decodable {
    struct Commit: Decodable {
        let sha: String
    }
    let name: String
    let commit: Commit

    var model: RemoteBranch { RemoteBranch(name: name, commitSHA: commit.sha) }
}

struct GitObjectDTO: Decodable {
    let type: String
    let sha: String
}

struct GitRefDTO: Decodable {
    let object: GitObjectDTO
}

struct GitTagDTO: Decodable {
    let object: GitObjectDTO
}

struct CreateReleaseDTO: Encodable {
    let tagName: String
    let targetCommitish: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let generateReleaseNotes: Bool
}

struct PullRequestDTO: Decodable {
    struct Label: Decodable {
        let name: String
    }
    struct Base: Decodable {
        let ref: String
    }
    let number: Int
    let title: String
    let htmlUrl: URL
    let mergedAt: Date?
    let user: AccountDTO?
    let labels: [Label]
    let base: Base?

    var model: RemotePullRequest {
        RemotePullRequest(
            number: number, title: title, authorLogin: user?.login, mergedAt: mergedAt,
            labels: labels.map(\.name), htmlURL: htmlUrl)
    }
}
