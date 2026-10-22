import Foundation

/// A GitHub repository linked to a local project. Identity is GitHub's numeric repository ID; owner and
/// name are refreshed on sync because repositories can be renamed or transferred.
public struct RepositoryConnection: Sendable, Hashable, Identifiable, Codable {
    public let id: UUID
    public let projectID: UUID
    public let githubRepositoryID: Int64
    public var owner: String
    public var name: String
    public var defaultBranch: String?
    public var htmlURL: URL
    public var isPrivate: Bool
    public var lastSyncedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public var fullName: String { "\(owner)/\(name)" }

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        githubRepositoryID: Int64,
        owner: String,
        name: String,
        defaultBranch: String?,
        htmlURL: URL,
        isPrivate: Bool,
        lastSyncedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.githubRepositoryID = githubRepositoryID
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.htmlURL = htmlURL
        self.isPrivate = isPrivate
        self.lastSyncedAt = lastSyncedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public struct GitHubAccount: Sendable, Hashable, Codable {
    public let id: Int64
    public let login: String
    public let name: String?
    public let htmlURL: URL

    public init(id: Int64, login: String, name: String?, htmlURL: URL) {
        self.id = id
        self.login = login
        self.name = name
        self.htmlURL = htmlURL
    }
}

/// Repository metadata as GitHub reports it now.
public struct GitHubRepository: Sendable, Hashable, Identifiable, Codable {
    public let id: Int64
    public let owner: String
    public let name: String
    public let defaultBranch: String?
    public let htmlURL: URL
    public let isPrivate: Bool
    public let description: String?

    public var fullName: String { "\(owner)/\(name)" }

    public init(
        id: Int64, owner: String, name: String, defaultBranch: String?, htmlURL: URL, isPrivate: Bool,
        description: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.name = name
        self.defaultBranch = defaultBranch
        self.htmlURL = htmlURL
        self.isPrivate = isPrivate
        self.description = description
    }
}

public struct RemoteRelease: Sendable, Hashable, Identifiable, Codable {
    public let id: Int64
    public let tagName: String
    public let name: String?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let createdAt: Date
    public let publishedAt: Date?
    public let targetCommitish: String
    public let htmlURL: URL
    public let body: String?

    public init(
        id: Int64, tagName: String, name: String?, isDraft: Bool, isPrerelease: Bool, createdAt: Date,
        publishedAt: Date?, targetCommitish: String, htmlURL: URL, body: String?
    ) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.createdAt = createdAt
        self.publishedAt = publishedAt
        self.targetCommitish = targetCommitish
        self.htmlURL = htmlURL
        self.body = body
    }
}

public struct RemoteTag: Sendable, Hashable, Codable {
    public let name: String
    public let commitSHA: String

    public init(name: String, commitSHA: String) {
        self.name = name
        self.commitSHA = commitSHA
    }
}

public struct RemoteCommit: Sendable, Hashable, Identifiable, Codable {
    public let sha: String
    public let message: String
    public let authorName: String?
    public let authorLogin: String?
    public let date: Date?
    public let htmlURL: URL
    /// Pull request numbers this commit belongs to (from GitHub, or parsed from the message).
    public var pullRequestNumbers: [Int]

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var summary: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }

    public init(
        sha: String, message: String, authorName: String?, authorLogin: String?, date: Date?, htmlURL: URL,
        pullRequestNumbers: [Int] = []
    ) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.date = date
        self.htmlURL = htmlURL
        self.pullRequestNumbers = pullRequestNumbers
    }
}

public struct RemotePullRequest: Sendable, Hashable, Identifiable, Codable {
    public let number: Int
    public let title: String
    public let authorLogin: String?
    public let mergedAt: Date?
    public let labels: [String]
    public let htmlURL: URL

    public var id: Int { number }

    public init(number: Int, title: String, authorLogin: String?, mergedAt: Date?, labels: [String], htmlURL: URL) {
        self.number = number
        self.title = title
        self.authorLogin = authorLogin
        self.mergedAt = mergedAt
        self.labels = labels
        self.htmlURL = htmlURL
    }
}

/// Commits on the default branch since the latest published release.
public struct UnreleasedChanges: Sendable, Hashable, Codable {
    /// Tag of the latest published release; `nil` when the repository has no release or tag yet.
    public let baseTag: String?
    public let headRef: String
    public let headSHA: String?
    public let totalCommits: Int
    public let commits: [RemoteCommit]
    public let pullRequests: [RemotePullRequest]
    /// Some commits beyond the fetch limit are not listed.
    public let isTruncated: Bool
    /// Pull requests were looked up for every listed commit (otherwise some were inferred from messages).
    public let pullRequestsComplete: Bool
    public let compareURL: URL?

    public init(
        baseTag: String?, headRef: String, headSHA: String?, totalCommits: Int, commits: [RemoteCommit],
        pullRequests: [RemotePullRequest], isTruncated: Bool, pullRequestsComplete: Bool, compareURL: URL?
    ) {
        self.baseTag = baseTag
        self.headRef = headRef
        self.headSHA = headSHA
        self.totalCommits = totalCommits
        self.commits = commits
        self.pullRequests = pullRequests
        self.isTruncated = isTruncated
        self.pullRequestsComplete = pullRequestsComplete
        self.compareURL = compareURL
    }
}

/// Everything Relvora knows about a repository from its last successful sync. Cached on disk; a failed
/// refresh never replaces it.
public struct RepositorySnapshot: Sendable, Hashable, Codable {
    public static let currentFormat = 1

    public var format: Int
    public var repository: GitHubRepository
    public var releases: [RemoteRelease]
    public var tags: [RemoteTag]
    public var unreleased: UnreleasedChanges?
    public var fetchedAt: Date
    /// Plain-language notes about missing or partial data.
    public var notes: [String]

    public init(
        repository: GitHubRepository, releases: [RemoteRelease], tags: [RemoteTag], unreleased: UnreleasedChanges?,
        fetchedAt: Date, notes: [String]
    ) {
        self.format = Self.currentFormat
        self.repository = repository
        self.releases = releases
        self.tags = tags
        self.unreleased = unreleased
        self.fetchedAt = fetchedAt
        self.notes = notes
    }

    /// The newest published (non-draft) release.
    public var latestPublishedRelease: RemoteRelease? {
        releases.filter { !$0.isDraft && $0.publishedAt != nil }.max { $0.publishedAt! < $1.publishedAt! }
    }
}
