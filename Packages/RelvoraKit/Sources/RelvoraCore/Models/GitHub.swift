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

public struct RemoteBranch: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let commitSHA: String

    public var id: String { name }

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
    /// The commits it follows: one, two for a merge. Empty when GitHub didn't say, as in caches from before 0.2.5.
    public var parentSHAs: [String]

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var summary: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }

    public init(
        sha: String, message: String, authorName: String?, authorLogin: String?, date: Date?, htmlURL: URL,
        pullRequestNumbers: [Int] = [], parentSHAs: [String] = []
    ) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.date = date
        self.htmlURL = htmlURL
        self.pullRequestNumbers = pullRequestNumbers
        self.parentSHAs = parentSHAs
    }

    /// Repository caches written before commits had parents still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        message = try container.decode(String.self, forKey: .message)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        authorLogin = try container.decodeIfPresent(String.self, forKey: .authorLogin)
        date = try container.decodeIfPresent(Date.self, forKey: .date)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        pullRequestNumbers = try container.decodeIfPresent([Int].self, forKey: .pullRequestNumbers) ?? []
        parentSHAs = try container.decodeIfPresent([String].self, forKey: .parentSHAs) ?? []
    }
}

/// How much a range of commits changes, from GitHub's comparison.
public struct ChangeStats: Sendable, Hashable, Codable {
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    /// GitHub lists at most 300 files in a comparison; the counts cover those only.
    public let isPartial: Bool

    public static let maximumFiles = 300

    public init(additions: Int, deletions: Int, changedFiles: Int, isPartial: Bool = false) {
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.isPartial = isPartial
    }

    /// GitHub's five-square bar: how many squares are additions, deletions, and unchanged (neutral). A change of any
    /// size fills all five; each kind that's present gets at least one.
    public var squares: (additions: Int, deletions: Int, neutral: Int) {
        let total = additions + deletions
        guard total > 0 else { return (0, 0, 5) }
        var added = Int((Double(additions) / Double(total) * 5).rounded())
        if additions > 0 { added = max(added, 1) }
        if deletions > 0 { added = min(added, 4) }
        return (added, 5 - added, 0)
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

/// Commits from a base tag to a head (the default branch for "unreleased", or a release's target commit), with
/// their merged pull requests.
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
    /// Lines added and removed from the base to the head; `nil` without a comparison, or in older caches.
    public let stats: ChangeStats?

    public init(
        baseTag: String?, headRef: String, headSHA: String?, totalCommits: Int, commits: [RemoteCommit],
        pullRequests: [RemotePullRequest], isTruncated: Bool, pullRequestsComplete: Bool, compareURL: URL?,
        stats: ChangeStats? = nil
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
        self.stats = stats
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
