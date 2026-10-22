import Foundation

/// One finding of the pre-draft check.
public struct ReleaseIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        /// The draft can't be created until this is resolved.
        case blocking
        /// Allowed, but the user should know. Incomplete tasks need explicit confirmation.
        case warning
        case note

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: Sendable, Hashable {
        case noRepository
        case repositoryDisconnected
        case noTargetCommit
        case noTag
        case invalidTag(String)
        /// The tag already exists and points at another commit. Relvora never moves a tag.
        case tagExists(tag: String, commitSHA: String)
        /// The tag already exists at the target commit; GitHub will use it as is.
        case tagExistsAtTarget(tag: String)
        case releasePublished(tag: String, url: URL)
        case draftExists(tag: String, url: URL)
        case notesTooLong
        case emptyNotes
        case incompleteTasks(count: Int)
        case noTasks
        case versionNotNewer(latest: String)
        case tagDoesNotMatchVersion(tag: String, version: String)
        case releaseListIncomplete
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public var id: Kind { kind }

    public var severity: Severity {
        switch kind {
        case .noRepository, .repositoryDisconnected, .noTargetCommit, .noTag, .invalidTag, .tagExists,
            .releasePublished, .draftExists, .notesTooLong:
            .blocking
        case .emptyNotes, .incompleteTasks, .versionNotNewer, .tagDoesNotMatchVersion, .releaseListIncomplete:
            .warning
        case .tagExistsAtTarget, .noTasks:
            .note
        }
    }

    public var message: String {
        switch kind {
        case .noRepository: "Choose the repository to release from."
        case .repositoryDisconnected: "The plan’s repository is no longer connected. Choose another one."
        case .noTargetCommit: "Choose the commit to release."
        case .noTag: "Enter a tag name."
        case .invalidTag(let tag): "“\(tag)” can’t be used as a Git tag."
        case .tagExists(let tag, let sha):
            "The tag \(tag) already exists at \(sha.prefix(7)), not at the chosen commit. Relvora never moves tags: choose another tag name or that commit."
        case .tagExistsAtTarget(let tag): "The tag \(tag) already exists at this commit. The release will use it."
        case .releasePublished(let tag, _): "A release for \(tag) is already published on GitHub."
        case .draftExists(let tag, _):
            "GitHub already has a draft release for \(tag). Publish or delete it on GitHub first."
        case .notesTooLong: "The notes are longer than GitHub allows (\(ReleaseNotes.maximumLength) characters)."
        case .emptyNotes: "The release notes are empty."
        case .incompleteTasks(let count):
            "\(count) \(count == 1 ? "task in this release isn’t" : "tasks in this release aren’t") complete. They stay on the board unchanged."
        case .noTasks: "No tasks are assigned to this release."
        case .versionNotNewer(let latest): "The latest published release, \(latest), isn’t older than this version."
        case .tagDoesNotMatchVersion(let tag, let version): "The tag \(tag) doesn’t match version \(version)."
        case .releaseListIncomplete: "Not every release on GitHub could be checked for this tag."
        }
    }
}

/// Everything known about a plan's readiness. Local findings need no network; remote ones come from GitHub.
public struct ReleaseCheck: Sendable, Equatable {
    public let issues: [ReleaseIssue]
    /// The repository as GitHub reports it now; `nil` for a local-only check.
    public let repository: GitHubRepository?
    /// A published release already using the plan's tag, which can be recorded instead of drafting a new one.
    public let publishedRelease: RemoteRelease?
    public let checkedAt: Date

    public init(
        issues: [ReleaseIssue], repository: GitHubRepository?, publishedRelease: RemoteRelease?, checkedAt: Date
    ) {
        self.issues = issues.sorted { $0.severity < $1.severity }
        self.repository = repository
        self.publishedRelease = publishedRelease
        self.checkedAt = checkedAt
    }

    public var isRemote: Bool { repository != nil }
    public var blockingIssues: [ReleaseIssue] { issues.filter { $0.severity == .blocking } }

    public var incompleteTaskCount: Int {
        issues.lazy.compactMap { if case .incompleteTasks(let count) = $0.kind { count } else { nil } }.first ?? 0
    }

    /// Ready for a draft: checked against GitHub, nothing blocking, and incomplete tasks confirmed by the user.
    public func allowsDraft(confirmingIncompleteTasks: Bool) -> Bool {
        isRemote && blockingIssues.isEmpty && (incompleteTaskCount == 0 || confirmingIncompleteTasks)
    }
}

/// The pre-draft rules, as pure functions.
public enum ReleaseChecker {
    /// Findings that need no network: target, tag, notes, and tasks.
    public static func localIssues(
        plan: ReleasePlan, tasks: [ProjectTask], connection: RepositoryConnection?
    ) -> [ReleaseIssue] {
        var issues: [ReleaseIssue] = []
        if plan.repositoryConnectionID == nil {
            issues.append(.init(.noRepository))
        } else if connection == nil {
            issues.append(.init(.repositoryDisconnected))
        }
        if plan.targetCommitSHA.map(GitRefName.isFullCommitSHA) != true { issues.append(.init(.noTargetCommit)) }
        switch plan.tagName {
        case nil: issues.append(.init(.noTag))
        case let tag? where !GitRefName.isValidTag(tag): issues.append(.init(.invalidTag(tag)))
        case let tag?:
            if !tagMatchesVersion(tag, plan: plan) {
                issues.append(.init(.tagDoesNotMatchVersion(tag: tag, version: plan.version)))
            }
        }
        if plan.changelogMarkdown.count > ReleaseNotes.maximumLength {
            issues.append(.init(.notesTooLong))
        } else if plan.changelogMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(.emptyNotes))
        }
        let planTasks = tasks.filter { $0.releasePlanID == plan.id }
        let open = planTasks.filter { $0.completedAt == nil }.count
        if planTasks.isEmpty {
            issues.append(.init(.noTasks))
        } else if open > 0 {
            issues.append(.init(.incompleteTasks(count: open)))
        }
        return issues
    }

    /// Findings from GitHub: existing tags and releases for the plan's tag, and version order.
    /// `tagCommitSHA` is where the tag points now (`nil` when it doesn't exist).
    public static func remoteIssues(
        plan: ReleasePlan, releases: [RemoteRelease], releasesTruncated: Bool, tagCommitSHA: String?
    ) -> [ReleaseIssue] {
        var issues: [ReleaseIssue] = []
        if let tag = plan.tagName {
            if let sha = tagCommitSHA {
                issues.append(
                    .init(
                        sha == plan.targetCommitSHA
                            ? .tagExistsAtTarget(tag: tag) : .tagExists(tag: tag, commitSHA: sha)))
            }
            for release in releases where release.tagName == tag {
                issues.append(
                    .init(
                        release.isDraft
                            ? .draftExists(tag: tag, url: release.htmlURL)
                            : .releasePublished(tag: tag, url: release.htmlURL)))
            }
        }
        if releasesTruncated { issues.append(.init(.releaseListIncomplete)) }
        if case .semantic(let version)? = try? ReleaseVersion(parsing: plan.version) {
            let published = releases.filter { !$0.isDraft }.compactMap { release in
                SemanticVersion(release.tagName).map { (release.tagName, $0) }
            }
            if let latest = published.max(by: { $0.1 < $1.1 }), !(latest.1 < version) {
                issues.append(.init(.versionNotNewer(latest: latest.0)))
            }
        }
        var seen = Set<ReleaseIssue>()
        return issues.filter { seen.insert($0).inserted }
    }

    static func tagMatchesVersion(_ tag: String, plan: ReleasePlan) -> Bool {
        switch try? ReleaseVersion(parsing: plan.version) {
        case .semantic(let version)?: SemanticVersion(tag) == version
        case .custom(let label)?: tag == plan.suggestedTagName || tag.contains(label)
        case nil: true
        }
    }
}

// MARK: - GitHub boundary

/// What the draft request asks GitHub to create.
public struct DraftReleaseRequest: Sendable, Equatable {
    public let tagName: String
    public let targetCommitSHA: String
    public let name: String
    public let body: String
    public let isPrerelease: Bool

    public init(tagName: String, targetCommitSHA: String, name: String, body: String, isPrerelease: Bool) {
        self.tagName = tagName
        self.targetCommitSHA = targetCommitSHA
        self.name = name
        self.body = body
        self.isPrerelease = isPrerelease
    }
}

/// The outcome of one create request, classified by whether GitHub may have acted on it.
public enum DraftCreationResult: Sendable {
    case created(RemoteRelease)
    /// GitHub refused the request, or it never left this Mac: nothing was created.
    case rejected(any Error)
    /// The request may have reached GitHub (timeout, dropped connection, server error). Read GitHub before retrying.
    case unknown(any Error)
}

/// The GitHub operations the release workflow needs. Implemented by `GitHubIntegration`; faked in tests.
public protocol ReleaseRemote: Sendable {
    /// The repository as GitHub reports it now (follows renames and transfers).
    func repository(id: Int64) async throws -> GitHubRepository
    /// Releases, drafts included, newest first, and whether the list was cut short.
    func releases(of repository: GitHubRepository) async throws -> (items: [RemoteRelease], truncated: Bool)
    /// `nil` when the release no longer exists.
    func release(of repository: GitHubRepository, id: Int64) async throws -> RemoteRelease?
    /// The commit a tag points at (annotated tags resolved), or `nil` when the tag doesn't exist.
    func tagCommitSHA(of repository: GitHubRepository, tag: String) async throws -> String?
    /// Sends exactly one create request; never retried automatically.
    func createDraftRelease(in repository: GitHubRepository, _ request: DraftReleaseRequest) async
        -> DraftCreationResult
}
