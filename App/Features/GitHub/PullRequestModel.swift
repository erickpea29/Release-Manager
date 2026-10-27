import Foundation
import GitHubIntegration
import Observation
import RelvoraCore

/// Pull requests and CI of connected repositories (ADR 0020), shared by the release plan, the GitHub tab, and the
/// watcher behind "CI finishes" notifications. GitHub is the source: nothing here is saved or backed up.
@Observable
final class PullRequestModel {
    struct Repository: Equatable {
        var open: [PullRequest] = []
        /// Merged in the last few days, newest first.
        var merged: [PullRequest] = []
        var mergeability: [Int: Mergeability] = [:]
        /// The latest commit of each branch asked for, such as the release's branch.
        var heads: [String: RemoteCommit] = [:]
        var fetchedAt: Date?
        var isLoading = false
        var error: String?
    }

    /// Open pull requests read in detail (whether they can merge, and their CI): the most recently updated ones.
    static let detailedLimit = 15
    /// How long a finished CI result is kept before it's read again: a check can be re-run.
    static let finishedCIMaxAge: TimeInterval = 10 * 60
    /// How long "no CI reported" is kept: CI may not have started yet on a new commit.
    static let unreportedCIMaxAge: TimeInterval = 2 * 60

    private(set) var repositories: [Int64: Repository] = [:]
    private(set) var ci: [Int64: [String: CIStatus]] = [:]
    /// Why CI can't be read in a repository, such as the Checks permission missing from the GitHub App.
    private(set) var ciProblems: [Int64: String] = [:]
    @ObservationIgnored private var ciReadAt: [Int64: [String: Date]] = [:]
    /// Finished CI already seen by the watcher, per repository: each outcome is announced once.
    @ObservationIgnored private var announced: [Int64: Set<String>] = [:]

    let github: GitHubModel

    init(github: GitHubModel) {
        self.github = github
    }

    func state(_ repositoryID: Int64) -> Repository { repositories[repositoryID] ?? Repository() }

    func ci(_ sha: String, in repositoryID: Int64) -> CIStatus? { ci[repositoryID]?[sha] }

    func readiness(_ pull: PullRequest, in repositoryID: Int64) -> MergeReadiness {
        MergeReadiness.of(
            pull, ci: ci(pull.headSHA, in: repositoryID), mergeability: state(repositoryID).mergeability[pull.number])
    }

    // MARK: Reading GitHub

    func refreshIfStale(repositoryID: Int64, branches: [String], maxAge: TimeInterval) async {
        let state = state(repositoryID)
        if let fetchedAt = state.fetchedAt, Date.now.timeIntervalSince(fetchedAt) < maxAge,
            Set(branches).isSubset(of: state.heads.keys)
        {
            return
        }
        await refresh(repositoryID: repositoryID, branches: branches)
    }

    /// Reads open and recently merged pull requests, whether each open one can merge, the latest commit of
    /// `branches`, and CI on all of them.
    func refresh(repositoryID: Int64, branches: [String]) async {
        guard github.isConnected, !state(repositoryID).isLoading else { return }
        repositories[repositoryID, default: Repository()].isLoading = true
        defer { repositories[repositoryID]?.isLoading = false }
        do {
            let open = try await github.openPullRequests(of: repositoryID)
            let closed = try await github.closedPullRequests(of: repositoryID)
            let detailed = open.prefix(Self.detailedLimit).filter { !$0.isDraft }
            var mergeability: [Int: Mergeability] = [:]
            await withTaskGroup(of: (Int, Mergeability?).self) { group in
                for pull in detailed {
                    group.addTask {
                        (pull.number, try? await self.github.pullRequest(of: repositoryID, number: pull.number).1)
                    }
                }
                for await (number, value) in group { mergeability[number] = value }
            }
            var heads: [String: RemoteCommit] = [:]
            for branch in Set(branches) {
                heads[branch] = try? await github.commit(of: repositoryID, ref: branch)
            }
            let merged = PullRequestRules.recentlyMerged(closed, into: nil, now: .now)
            var state = state(repositoryID)
            state.open = open
            state.merged = merged
            state.mergeability = mergeability
            state.heads.merge(heads) { _, new in new }
            state.fetchedAt = .now
            state.error = nil
            repositories[repositoryID] = state
            let shas =
                open.prefix(Self.detailedLimit).map(\.headSHA) + merged.compactMap(\.mergeCommitSHA)
                + heads.values.map(\.sha)
            await loadCI(shas, in: repositoryID)
        } catch {
            repositories[repositoryID]?.error = AppAlert.message(for: error)
        }
    }

    /// CI for commits, reading only what isn't known yet, still runs, or was read a while ago.
    func loadCI(_ shas: [String], in repositoryID: Int64) async {
        let now = Date.now
        let due = Set(shas).filter { sha in
            guard let status = ci(sha, in: repositoryID), let readAt = ciReadAt[repositoryID]?[sha] else { return true }
            let maxAge: TimeInterval =
                switch status {
                case .running: 0
                case .notReported: Self.unreportedCIMaxAge
                case .passed, .failed: Self.finishedCIMaxAge
                }
            return now.timeIntervalSince(readAt) >= maxAge
        }
        guard !due.isEmpty, github.isConnected else { return }
        var problem: String?
        await withTaskGroup(of: (String, Result<CIStatus, any Error>).self) { group in
            for sha in due {
                group.addTask {
                    do {
                        return (sha, .success(CIStatus(try await self.github.checkRuns(of: repositoryID, sha: sha))))
                    } catch {
                        return (sha, .failure(error))
                    }
                }
            }
            for await (sha, result) in group {
                switch result {
                case .success(let status):
                    ci[repositoryID, default: [:]][sha] = status
                    ciReadAt[repositoryID, default: [:]][sha] = .now
                case .failure(GitHubError.forbidden):
                    problem =
                        "Relvora can’t read CI here yet: the Relvora GitHub App needs the Checks permission (read). "
                        + "Add it in the app’s settings on GitHub, then accept it for your installation."
                case .failure:
                    // Kept as it was; the next refresh tries again.
                    break
                }
            }
        }
        if problem != nil || ciProblems[repositoryID] != nil { ciProblems[repositoryID] = problem }
    }

    // MARK: Merging

    /// Merges after the user confirmed, only at the head commit they were shown. Returns the commit the merge created.
    /// When the outcome is unknown (a timeout), the pull request is read to find out.
    func merge(_ pull: PullRequest, method: MergeMethod, in repositoryID: Int64) async throws -> String {
        let sha: String
        do {
            sha = try await github.mergePullRequest(
                of: repositoryID, number: pull.number, headSHA: pull.headSHA, method: method)
        } catch GitHubError.conflict {
            throw MergeError.branchMoved
        } catch let error as GitHubError where error.mayHaveReachedGitHub {
            guard let current = try? await github.pullRequest(of: repositoryID, number: pull.number).pullRequest
            else { throw MergeError.outcomeUnknown }
            guard current.state == .merged, let merged = current.mergeCommitSHA else { throw error }
            sha = merged
        }
        if var state = repositories[repositoryID] {
            state.open.removeAll { $0.number == pull.number }
            repositories[repositoryID] = state
        }
        return sha
    }

    enum MergeError: LocalizedError {
        case branchMoved
        case outcomeUnknown

        var errorDescription: String? {
            switch self {
            case .branchMoved:
                "The pull request got new commits after Relvora showed it, so GitHub didn’t merge it."
            case .outcomeUnknown:
                "Relvora couldn’t tell whether GitHub merged the pull request."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .branchMoved: "Wait for CI on the new commits, then merge again."
            case .outcomeUnknown: "Refresh to see its state, or open it on GitHub."
            }
        }
    }

    // MARK: Notifications

    /// CI that finished since the last call, for "CI finishes" notifications. The first call for a repository, once
    /// its CI can be read, only remembers what had finished.
    func takeFinished(repositoryID: Int64, branches: [String]) -> [CIRun] {
        let state = state(repositoryID)
        guard state.fetchedAt != nil, state.error == nil, ciProblems[repositoryID] == nil else { return [] }
        var runs: [CIRun] = state.open.compactMap { pull in
            ci(pull.headSHA, in: repositoryID).map { status in
                CIRun(
                    subject: .pullRequest(number: pull.number, title: pull.title, baseRef: pull.baseRef),
                    sha: pull.headSHA, status: status, readiness: readiness(pull, in: repositoryID))
            }
        }
        for branch in branches {
            guard let head = state.heads[branch], let status = ci(head.sha, in: repositoryID) else { continue }
            runs.append(CIRun(subject: .branch(branch, commitSummary: head.summary), sha: head.sha, status: status))
        }
        let finished = PullRequestRules.newlyFinished(runs, known: announced[repositoryID])
        announced[repositoryID, default: []].formUnion(runs.compactMap(\.key))
        return finished
    }
}
