import Foundation

/// A pull request as Relvora shows it beside a release (ADR 0020): open ones with their CI, and recently merged ones.
public struct PullRequest: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        case open
        case merged
        case closed
    }

    public let number: Int
    public let title: String
    public let authorLogin: String?
    public let state: State
    public let isDraft: Bool
    /// The branch it merges from, and that branch's latest commit: the one CI runs on.
    public let headRef: String
    public let headSHA: String
    /// The branch it merges into.
    public let baseRef: String
    public let mergedAt: Date?
    /// The commit the merge created on the base branch.
    public let mergeCommitSHA: String?
    public let updatedAt: Date?
    public let htmlURL: URL

    public var id: Int { number }

    public init(
        number: Int, title: String, authorLogin: String?, state: State, isDraft: Bool, headRef: String,
        headSHA: String, baseRef: String, mergedAt: Date?, mergeCommitSHA: String?, updatedAt: Date?, htmlURL: URL
    ) {
        self.number = number
        self.title = title
        self.authorLogin = authorLogin
        self.state = state
        self.isDraft = isDraft
        self.headRef = headRef
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.mergedAt = mergedAt
        self.mergeCommitSHA = mergeCommitSHA
        self.updatedAt = updatedAt
        self.htmlURL = htmlURL
    }
}

/// What GitHub says about merging an open pull request. GitHub's list of pull requests leaves it out, so it's read for
/// each one.
public struct Mergeability: Sendable, Hashable {
    /// `nil` while GitHub is still working it out.
    public let isMergeable: Bool?
    /// GitHub's `mergeable_state`: clean, unstable, has_hooks, blocked, behind, dirty, draft, or unknown.
    public let state: String

    public init(isMergeable: Bool?, state: String) {
        self.isMergeable = isMergeable
        self.state = state
    }
}

/// One CI check on a commit: a GitHub check run, such as a GitHub Actions job.
public struct CheckRun: Sendable, Hashable {
    public let name: String
    public let isCompleted: Bool
    /// success, failure, neutral, cancelled, skipped, timed_out, action_required…; `nil` until completed.
    public let conclusion: String?
    public let htmlURL: URL?

    public init(name: String, isCompleted: Bool, conclusion: String?, htmlURL: URL?) {
        self.name = name
        self.isCompleted = isCompleted
        self.conclusion = conclusion
        self.htmlURL = htmlURL
    }

    /// Conclusions that mean the check didn't pass. Neutral and skipped checks don't block anything.
    static let failingConclusions: Set<String> = [
        "failure", "timed_out", "cancelled", "action_required", "startup_failure",
    ]

    public var isFailing: Bool { isCompleted && Self.failingConclusions.contains(conclusion ?? "") }
}

/// A commit's CI, summarized from its checks.
public enum CIStatus: Sendable, Hashable {
    /// No check reported on the commit: the repository has no CI, or it hasn't started.
    case notReported
    case running(finished: Int, total: Int)
    case passed(total: Int)
    /// The failing checks by name, reported as soon as one fails, even while others still run.
    case failed(checks: [String], total: Int)

    public enum Outcome: String, Sendable {
        case passed
        case failed
    }

    public init(_ runs: [CheckRun]) {
        guard !runs.isEmpty else {
            self = .notReported
            return
        }
        var seen = Set<String>()
        let failing = runs.filter(\.isFailing).map(\.name).filter { seen.insert($0).inserted }
        let finished = runs.filter(\.isCompleted).count
        if !failing.isEmpty {
            self = .failed(checks: failing, total: runs.count)
        } else if finished < runs.count {
            self = .running(finished: finished, total: runs.count)
        } else {
            self = .passed(total: runs.count)
        }
    }

    /// Passed or failed: what a notification announces. Running CI, and none, have no outcome yet.
    public var outcome: Outcome? {
        switch self {
        case .passed: .passed
        case .failed: .failed
        case .notReported, .running: nil
        }
    }

    /// The failing checks, as a sentence: "UI tests", "Lint and UI tests", "Build, Lint, and 2 more".
    public var failingChecks: String? {
        guard case .failed(let checks, _) = self else { return nil }
        switch checks.count {
        case 0: return nil
        case 1: return checks[0]
        case 2: return "\(checks[0]) and \(checks[1])"
        case 3: return "\(checks[0]), \(checks[1]), and \(checks[2])"
        default: return "\(checks[0]), \(checks[1]), and \(checks.count - 2) more"
        }
    }

    public var title: String {
        switch self {
        case .notReported: "No CI reported"
        case .running(let finished, let total): "CI running (\(finished) of \(total) done)"
        case .passed: "CI passed"
        case .failed: "CI failed: \(failingChecks ?? "")"
        }
    }
}

/// Whether Relvora offers to merge an open pull request now.
public enum MergeReadiness: Sendable, Hashable {
    case ready
    case draft
    case conflicts
    case ciFailed
    case waitingForCI
    /// Relvora couldn't read the CI, for example without the Checks permission, so it can't tell that CI passed.
    case ciUnknown
    /// The branch rules require it to be up to date with its base branch first.
    case behind
    /// The branch rules block it, for example until a required review.
    case blocked
    /// GitHub is still working out whether it can merge.
    case checking
    case notOpen

    /// Merging is offered only once CI passed (or the repository reports no CI) and GitHub says it can merge.
    public static func of(_ pull: PullRequest, ci: CIStatus?, mergeability: Mergeability?) -> MergeReadiness {
        guard pull.state == .open else { return .notOpen }
        if pull.isDraft { return .draft }
        if mergeability?.isMergeable == false || mergeability?.state == "dirty" { return .conflicts }
        guard let ci else { return .ciUnknown }
        switch ci {
        case .failed: return .ciFailed
        case .running: return .waitingForCI
        case .passed, .notReported: break
        }
        switch mergeability?.state {
        case "behind": return .behind
        case "blocked": return .blocked
        case nil, "unknown": return .checking
        default: return mergeability?.isMergeable == true ? .ready : .checking
        }
    }

    public var canMerge: Bool { self == .ready }

    public var summary: String {
        switch self {
        case .ready: "Ready to merge"
        case .draft: "Draft: mark it ready for review on GitHub first"
        case .conflicts: "Has conflicts with its base branch"
        case .ciFailed: "CI failed"
        case .waitingForCI: "Waiting for CI"
        case .ciUnknown: "Relvora can’t read its CI"
        case .behind: "Out of date with its base branch: update it on GitHub"
        case .blocked: "Blocked by the branch’s rules, such as a required review"
        case .checking: "GitHub is checking whether it can merge"
        case .notOpen: "Not open"
        }
    }
}

/// How GitHub merges a pull request. The repository's settings may allow only some of them.
public enum MergeMethod: String, Sendable, CaseIterable, Identifiable, Codable {
    case merge
    case squash
    case rebase

    public var id: Self { self }

    public var title: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }
}

/// Something CI runs on that Relvora watches: an open pull request's latest commit, or a branch's latest commit.
public struct CIRun: Sendable, Hashable {
    public enum Subject: Sendable, Hashable {
        case pullRequest(number: Int, title: String, baseRef: String)
        case branch(String, commitSummary: String)
    }

    public let subject: Subject
    public let sha: String
    public let status: CIStatus
    /// For a pull request: whether Relvora would offer to merge it now.
    public let readiness: MergeReadiness?

    public init(subject: Subject, sha: String, status: CIStatus, readiness: MergeReadiness? = nil) {
        self.subject = subject
        self.sha = sha
        self.status = status
        self.readiness = readiness
    }

    /// The outcome on this commit, announced once: "pr-15 <sha> passed", "branch-main <sha> failed".
    public var key: String? {
        guard let outcome = status.outcome else { return nil }
        let subject =
            switch subject {
            case .pullRequest(let number, _, _): "pr-\(number)"
            case .branch(let name, _): "branch-\(name)"
            }
        return "\(subject) \(sha) \(outcome.rawValue)"
    }
}

/// Rules for pull requests beside a release. Pure, so they're tested without GitHub.
public enum PullRequestRules {
    /// How long a merged pull request is listed as recently merged.
    public static let recentlyMergedDays = 3
    public static let recentlyMergedLimit = 5

    /// Merged pull requests from the last few days, newest first, into `base` when one is given.
    public static func recentlyMerged(_ pulls: [PullRequest], into base: String?, now: Date) -> [PullRequest] {
        let since = now.addingTimeInterval(-Double(recentlyMergedDays) * 86_400)
        return
            pulls
            .filter { pull in
                guard pull.state == .merged, let mergedAt = pull.mergedAt, mergedAt >= since else { return false }
                return base == nil || pull.baseRef == base
            }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
            .prefix(recentlyMergedLimit)
            .map(\.self)
    }

    /// The newest of `commits` (newest first) whose CI passed. Commits whose CI isn't known are skipped.
    public static func latestPassing(_ commits: [RemoteCommit], ci: [String: CIStatus]) -> RemoteCommit? {
        commits.first { commit in
            if case .passed? = ci[commit.sha] { true } else { false }
        }
    }

    /// Finished CI not announced before. The first look at a repository (`known` is `nil`) only remembers: what had
    /// finished before Relvora was watching isn't announced.
    public static func newlyFinished(_ runs: [CIRun], known: Set<String>?) -> [CIRun] {
        guard let known else { return [] }
        return runs.filter { run in run.key.map { !known.contains($0) } ?? false }
    }
}

extension AppNotifications {
    /// "#15 is ready to merge", "CI failed on #15", "main is ready for Relvora 0.2.3"…; `nil` while CI still runs.
    /// `version` is the version being planned from the repository, if any.
    public static func ciFinished(
        _ run: CIRun, projectID: UUID, projectName: String, repository: String, version: String?
    ) -> NotificationContent? {
        guard let key = run.key else { return nil }
        let title: String
        let body: String
        switch (run.subject, run.status) {
        case (.pullRequest(let number, let name, let base), .passed):
            if run.readiness == .ready {
                title = "#\(number) is ready to merge"
                body = "CI passed on “\(name)” in \(repository). You can merge it into \(base) from Relvora."
            } else {
                title = "CI passed on #\(number)"
                body = "“\(name)” in \(repository). " + (run.readiness.map { "\($0.summary)." } ?? "")
            }
        case (.pullRequest(let number, let name, _), _):
            title = "CI failed on #\(number)"
            body = "\(run.status.failingChecks ?? "A check") failed on “\(name)” in \(repository)."
        case (.branch(let branch, let summary), .passed):
            title = version.map { "\(branch) is ready for \(projectName) \($0)" } ?? "CI passed on \(branch)"
            body =
                "CI passed at \(run.sha.prefix(7)) “\(summary)” in \(repository)."
                + (version == nil ? "" : " Choose it as the release’s commit in Relvora.")
        case (.branch(let branch, let summary), _):
            title = "CI failed on \(branch)"
            body =
                "\(run.status.failingChecks ?? "A check") failed at \(run.sha.prefix(7)) “\(summary)” in "
                + "\(repository)."
        }
        return NotificationContent(
            id: "ci-\(key)", kind: .ciFinished, title: title, body: body.trimmingCharacters(in: .whitespaces),
            threadID: projectID.uuidString, target: .project(projectID, tab: "releases"))
    }
}
