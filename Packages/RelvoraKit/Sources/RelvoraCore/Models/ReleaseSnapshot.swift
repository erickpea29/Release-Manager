import Foundation

/// Where a release snapshot stands on GitHub.
public enum ReleaseSnapshotState: String, Sendable, CaseIterable, Codable {
    /// The create request was sent but GitHub has not confirmed it. Resolved only by re-reading GitHub.
    case pending
    case draftCreated
    /// Published on GitHub, with the tag verified to point at the recorded commit.
    case published
    /// The draft was deleted on GitHub before it was published.
    case abandoned

    public var title: String {
        switch self {
        case .pending: "Needs reconciliation"
        case .draftCreated: "Draft on GitHub"
        case .published: "Published"
        case .abandoned: "Draft deleted"
        }
    }

    /// A snapshot that still represents the plan's current GitHub draft.
    public var isOpen: Bool { self == .pending || self == .draftCreated }
}

/// How the snapshot came to exist.
public enum ReleaseSnapshotOrigin: String, Sendable, Codable {
    /// Relvora created the GitHub draft.
    case relvoraDraft
    /// The release was created and published on GitHub; Relvora recorded it afterwards.
    case external
}

/// A task as it was when the release snapshot was taken.
public struct TaskSnapshot: Sendable, Hashable, Codable, Identifiable {
    /// The source task's ID, for reference only. The task may since have changed or been deleted.
    public let id: UUID
    public let title: String
    public let details: String?
    public let type: TaskType
    public let priority: TaskPriority
    public let labels: [String]
    public let isCompleted: Bool
    public let completedAt: Date?
    public let columnName: String?
    public let checklistDone: Int
    public let checklistTotal: Int

    public init(_ task: ProjectTask, columnName: String?) {
        self.id = task.id
        self.title = task.title
        self.details = task.details
        self.type = task.type
        self.priority = task.priority
        self.labels = task.labels
        self.isCompleted = task.completedAt != nil
        self.completedAt = task.completedAt
        self.columnName = columnName
        self.checklistDone = task.checklist.filter(\.isDone).count
        self.checklistTotal = task.checklist.count
    }
}

/// The GitHub changes a release was prepared from.
public struct ReleaseChangeSummary: Sendable, Hashable, Codable {
    public let baseTag: String?
    public let totalCommits: Int
    public let pullRequests: [RemotePullRequest]
    public let compareURL: URL?
    /// Every commit was listed and every pull request was looked up.
    public let isComplete: Bool

    public init(
        baseTag: String?, totalCommits: Int, pullRequests: [RemotePullRequest], compareURL: URL?, isComplete: Bool
    ) {
        self.baseTag = baseTag
        self.totalCommits = totalCommits
        self.pullRequests = pullRequests
        self.compareURL = compareURL
        self.isComplete = isComplete
    }

    public init(_ changes: UnreleasedChanges) {
        self.init(
            baseTag: changes.baseTag, totalCommits: changes.totalCommits, pullRequests: changes.pullRequests,
            compareURL: changes.compareURL, isComplete: changes.pullRequestsComplete && !changes.isTruncated)
    }
}

/// An immutable record of a release.
///
/// Content is frozen when the draft is requested: version, tag, target commit, notes as submitted, and the plan's
/// tasks as they were. Later task edits never change it. Only lifecycle fields change, each at most once, through
/// `applying(_:)`; the store refuses anything else.
public struct ReleaseSnapshot: Sendable, Hashable, Identifiable {
    // MARK: Content (write-once)
    public let id: UUID
    public let projectID: UUID
    public let releasePlanID: UUID?
    public let origin: ReleaseSnapshotOrigin
    public let version: String
    public let title: String?
    public let releaseName: String
    public let tagName: String
    public let targetCommitSHA: String
    public let targetBranch: String?
    public let isPrerelease: Bool
    public let releaseNotesMarkdown: String
    public let tasks: [TaskSnapshot]
    public let changes: ReleaseChangeSummary?
    public let githubRepositoryID: Int64
    /// `owner/name` when the snapshot was taken.
    public let repositoryFullName: String
    public let repositoryURL: URL
    public let snapshotCreatedAt: Date

    // MARK: Lifecycle (each field set at most once)
    public private(set) var state: ReleaseSnapshotState
    public private(set) var githubReleaseID: Int64?
    public private(set) var githubReleaseURL: URL?
    public private(set) var publishedAt: Date?
    /// GitHub's notes at publication, stored only when they differ from the submitted notes.
    public private(set) var publishedNotesMarkdown: String?
    /// The tag name at publication, stored only when it differs from `tagName` (accepted by the user).
    public private(set) var publishedTagName: String?
    /// The commit the published tag resolved to when publication was verified.
    public private(set) var publishedCommitSHA: String?
    public private(set) var stateChangedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        releasePlanID: UUID?,
        origin: ReleaseSnapshotOrigin,
        version: String,
        title: String?,
        releaseName: String,
        tagName: String,
        targetCommitSHA: String,
        targetBranch: String?,
        isPrerelease: Bool,
        releaseNotesMarkdown: String,
        tasks: [TaskSnapshot],
        changes: ReleaseChangeSummary?,
        githubRepositoryID: Int64,
        repositoryFullName: String,
        repositoryURL: URL,
        snapshotCreatedAt: Date,
        state: ReleaseSnapshotState = .pending,
        githubReleaseID: Int64? = nil,
        githubReleaseURL: URL? = nil,
        publishedAt: Date? = nil,
        publishedNotesMarkdown: String? = nil,
        publishedTagName: String? = nil,
        publishedCommitSHA: String? = nil,
        stateChangedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.releasePlanID = releasePlanID
        self.origin = origin
        self.version = version
        self.title = title
        self.releaseName = releaseName
        self.tagName = tagName
        self.targetCommitSHA = targetCommitSHA
        self.targetBranch = targetBranch
        self.isPrerelease = isPrerelease
        self.releaseNotesMarkdown = releaseNotesMarkdown
        self.tasks = tasks
        self.changes = changes
        self.githubRepositoryID = githubRepositoryID
        self.repositoryFullName = repositoryFullName
        self.repositoryURL = repositoryURL
        self.snapshotCreatedAt = snapshotCreatedAt
        self.state = state
        self.githubReleaseID = githubReleaseID
        self.githubReleaseURL = githubReleaseURL
        self.publishedAt = publishedAt
        self.publishedNotesMarkdown = publishedNotesMarkdown
        self.publishedTagName = publishedTagName
        self.publishedCommitSHA = publishedCommitSHA
        self.stateChangedAt = stateChangedAt ?? snapshotCreatedAt
    }

    /// The notes as they read on GitHub at publication (or as submitted).
    public var effectiveNotesMarkdown: String { publishedNotesMarkdown ?? releaseNotesMarkdown }
    public var effectiveTagName: String { publishedTagName ?? tagName }
    public var effectiveCommitSHA: String { publishedCommitSHA ?? targetCommitSHA }
    public var commitURL: URL { repositoryURL.appending(path: "commit/\(effectiveCommitSHA)") }
    /// The tag's page; only meaningful once published (a draft's tag does not exist yet).
    public var tagURL: URL { repositoryURL.appending(path: "releases/tag/\(effectiveTagName)") }
}

/// The only ways a snapshot can change after it is created.
public enum SnapshotTransition: Sendable, Equatable {
    /// GitHub confirmed the draft: `pending` → `draftCreated`.
    case draftConfirmed(releaseID: Int64, url: URL)
    /// Publication verified: `draftCreated` → `published`.
    case published(at: Date, url: URL, notes: String?, tagName: String, commitSHA: String)
    /// The draft no longer exists on GitHub: `draftCreated` → `abandoned`.
    case abandoned
}

extension ReleaseSnapshot {
    /// The snapshot after `transition`, or `nil` when the transition isn't allowed from the current state.
    /// Content fields are never touched. Lifecycle fields are only filled in, never replaced, except the release
    /// URL: GitHub moves a draft's `untagged-…` page to the tag's page when it is published.
    public func applying(_ transition: SnapshotTransition, at date: Date) -> ReleaseSnapshot? {
        var next = self
        switch (state, transition) {
        case (.pending, .draftConfirmed(let releaseID, let url)):
            guard githubReleaseID == nil else { return nil }
            next.state = .draftCreated
            next.githubReleaseID = releaseID
            next.githubReleaseURL = url
        case (.draftCreated, .published(let publishedAt, let url, let notes, let tagName, let commitSHA)):
            guard self.publishedAt == nil else { return nil }
            next.state = .published
            next.githubReleaseURL = url
            next.publishedAt = publishedAt
            next.publishedNotesMarkdown = notes.flatMap {
                ReleaseNotes.normalized($0) == ReleaseNotes.normalized(releaseNotesMarkdown) ? nil : $0
            }
            next.publishedTagName = tagName == self.tagName ? nil : tagName
            next.publishedCommitSHA = commitSHA
        case (.draftCreated, .abandoned):
            next.state = .abandoned
        default:
            return nil
        }
        next.stateChangedAt = date
        return next
    }
}

public enum ReleaseNotes {
    /// GitHub's maximum release body length.
    public static let maximumLength = 125_000

    /// For comparing notes: GitHub may return edited bodies with CRLF line endings or trailing whitespace.
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/\s+$/, with: "") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
