import Foundation
import RelvoraCore

/// Builds a `RepositorySnapshot`: current metadata, releases, tags, and the unreleased changes on the default
/// branch (commits since the latest published release, with their merged pull requests).
public struct GitHubSyncService: Sendable {
    /// Pull requests are looked up per commit for the newest commits only, to bound API usage;
    /// older commits are matched by PR numbers in their messages.
    public static let pullRequestLookupLimit = 40
    public static let maxCommitPages = 3

    private let api: GitHubAPIClient
    private let now: @Sendable () -> Date

    public init(api: GitHubAPIClient, now: @escaping @Sendable () -> Date = { .now }) {
        self.api = api
        self.now = now
    }

    public func snapshot(repositoryID: Int64) async throws(GitHubError) -> RepositorySnapshot {
        let repository = try await api.repository(id: repositoryID)
        var notes: [String] = []

        let (releases, releasesTruncated) = try await api.releases(of: repository)
        if releasesTruncated { notes.append("Only the latest \(releases.count) releases are shown.") }
        let (tags, tagsTruncated) = try await api.tags(of: repository)
        if tagsTruncated { notes.append("Only the latest \(tags.count) tags are shown.") }

        var snapshot = RepositorySnapshot(
            repository: repository, releases: releases, tags: tags, unreleased: nil, fetchedAt: now(), notes: [])
        snapshot.unreleased = try await unreleasedChanges(
            repository, base: Self.baseTag(latestRelease: snapshot.latestPublishedRelease, tags: tags), notes: &notes)
        snapshot.notes = notes
        return snapshot
    }

    /// The latest published release's tag; otherwise the highest semantic-version tag; otherwise GitHub's first
    /// tag; otherwise none. Non-version tags (such as `nightly`) are never preferred over versions.
    public static func baseTag(latestRelease: RemoteRelease?, tags: [RemoteTag]) -> String? {
        if let latestRelease { return latestRelease.tagName }
        let versions = tags.compactMap { tag in SemanticVersion(tag.name).map { (tag.name, $0) } }
        return versions.max { $0.1 < $1.1 }?.0 ?? tags.first?.name
    }

    private func unreleasedChanges(_ repository: GitHubRepository, base: String?, notes: inout [String])
        async throws(GitHubError) -> UnreleasedChanges?
    {
        guard let branch = repository.defaultBranch else {
            notes.append("The repository has no default branch, so unreleased changes can’t be listed.")
            return nil
        }
        let result = try await changes(in: repository, base: base, head: branch, branch: branch)
        notes += result.notes
        return result.changes
    }

    /// Commits from `base` to `head` (a branch or commit SHA), newest first, with the pull requests merged into
    /// `branch` that contain them. Without a base, or when the base tag is gone, the latest commits are used.
    public func changes(in repository: GitHubRepository, base: String?, head: String, branch: String?)
        async throws(GitHubError) -> (changes: UnreleasedChanges, notes: [String])
    {
        var notes: [String] = []
        var commits: [RemoteCommit]
        var total: Int
        var compareURL: URL?
        var resolvedBase = base
        if let base {
            do {
                let result = try await api.compare(repository, base: base, head: head, maxPages: Self.maxCommitPages)
                commits = result.commits.reversed()  // newest first
                total = result.totalCommits
                compareURL = result.htmlURL
            } catch .notFound {
                notes.append("Couldn’t compare with \(base) (the tag may have been deleted). Showing recent commits.")
                commits = try await api.commits(of: repository, branch: head)
                total = commits.count
                resolvedBase = nil
            }
        } else {
            commits = try await api.commits(of: repository, branch: head)
            total = commits.count
            if !commits.isEmpty {
                notes.append("No releases or tags yet. Showing the latest \(commits.count) commits.")
            }
        }
        let isTruncated = total > commits.count
        if isTruncated, let resolvedBase {
            notes.append("Showing \(commits.count) of \(total) commits since \(resolvedBase).")
        }

        var pullRequests: [Int: RemotePullRequest] = [:]
        for index in commits.indices.prefix(Self.pullRequestLookupLimit) {
            let found = try await api.pullRequests(of: repository, containing: commits[index].sha)
            let merged = found.filter {
                $0.pullRequest.mergedAt != nil && (branch == nil || $0.baseRef == nil || $0.baseRef == branch)
            }
            for item in merged { pullRequests[item.pullRequest.number] = item.pullRequest }
            commits[index].pullRequestNumbers = merged.map(\.pullRequest.number).sorted()
        }
        let complete = commits.count <= Self.pullRequestLookupLimit
        if !complete {
            for index in commits.indices.dropFirst(Self.pullRequestLookupLimit) {
                commits[index].pullRequestNumbers = PullRequestReferences.numbers(in: commits[index].message)
            }
            notes.append(
                "Pull requests were looked up for the newest \(Self.pullRequestLookupLimit) commits; older ones were "
                    + "matched from commit messages.")
        }

        let changes = UnreleasedChanges(
            baseTag: resolvedBase,
            headRef: head,
            headSHA: commits.first?.sha,
            totalCommits: total,
            commits: commits,
            pullRequests: pullRequests.values.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) },
            isTruncated: isTruncated,
            pullRequestsComplete: complete,
            compareURL: compareURL
        )
        return (changes, notes)
    }
}

/// When a repository is due for an automatic refresh: once `interval` has passed since the last successful sync and
/// since the last attempt (so a failure waits a full interval too), and never while GitHub's rate limit is used up.
public enum RefreshSchedule {
    public static func isDue(
        lastSynced: Date?, lastAttempt: Date?, interval: TimeInterval, rateLimitedUntil: Date?, now: Date
    ) -> Bool {
        if let rateLimitedUntil, now < rateLimitedUntil { return false }
        guard let last = [lastSynced, lastAttempt].compactMap(\.self).max() else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}

/// Finds pull request numbers in commit messages written by GitHub's merge and squash buttons.
public enum PullRequestReferences {
    public static func numbers(in message: String) -> [Int] {
        let summary = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        var found: [Int] = []
        // "Merge pull request #12 from owner/branch"
        if let match = summary.firstMatch(of: /^Merge pull request #(\d+)/), let number = Int(match.1) {
            found.append(number)
        }
        // "Add feature (#12)" — squash merges
        if let match = summary.firstMatch(of: /\(#(\d+)\)\s*$/), let number = Int(match.1) {
            found.append(number)
        }
        return Array(Set(found)).sorted()
    }
}

/// Last successful snapshot per repository, as JSON files. Disposable: re-downloadable, excluded from
/// backups, and never replaced by a failed refresh (callers save only successful snapshots).
public struct SnapshotCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Relvora", directoryHint: .isDirectory)
            .appending(path: "GitHub Cache", directoryHint: .isDirectory)
    }

    private func url(for repositoryID: Int64) -> URL { directory.appending(path: "\(repositoryID).json") }

    /// `nil` when missing, unreadable, or written by an incompatible format.
    public func load(repositoryID: Int64) -> RepositorySnapshot? {
        guard let data = try? Data(contentsOf: url(for: repositoryID)),
            let snapshot = try? JSONDecoder().decode(RepositorySnapshot.self, from: data),
            snapshot.format == RepositorySnapshot.currentFormat
        else { return nil }
        return snapshot
    }

    public func save(_ snapshot: RepositorySnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url(for: snapshot.repository.id), options: .atomic)
    }

    public func delete(repositoryID: Int64) {
        try? FileManager.default.removeItem(at: url(for: repositoryID))
    }
}
