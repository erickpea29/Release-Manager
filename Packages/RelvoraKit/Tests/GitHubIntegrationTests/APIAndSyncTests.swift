import Foundation
import RelvoraCore
import Testing

@testable import GitHubIntegration

private let repository = GitHubRepository(
    id: 42, owner: "octo", name: "app", defaultBranch: "main",
    htmlURL: URL(string: "https://github.com/octo/app")!, isPrivate: true)

@Suite("API client")
struct APIClientTests {
    @Test("Requests carry the bearer token, media type, and pinned API version")
    func headers() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", json: Payload.repository)
        let repo = try await harness.api.repository(id: 42)
        #expect(
            repo
                == GitHubRepository(
                    id: 42, owner: "octo", name: "app", defaultBranch: "main",
                    htmlURL: URL(string: "https://github.com/octo/app")!, isPrivate: true, description: "The app"))
        let request = try #require(await harness.mock.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_OLD")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("Pagination stops at the page limit and reports truncation")
    func pagination() async throws {
        let harness = Harness()
        let next = #"<https://api.github.com/repos/octo/app/tags?per_page=100&page=2>; rel="next""#
        await harness.mock.on(
            "/repos/octo/app/tags",
            .init(headers: ["Link": next], body: Payload.tags),
            .init(headers: ["Link": next], body: Payload.tags))
        let (tags, truncated) = try await harness.api.tags(of: repository, maxPages: 2)
        #expect(tags.count == 4 && truncated)
        #expect(await harness.mock.requests.count == 2)
    }

    @Test("Pagination links to another host are never followed")
    func foreignLink() async throws {
        let harness = Harness()
        let evil = #"<https://evil.example.com/steal?page=2>; rel="next""#
        await harness.mock.on("/repos/octo/app/tags", .init(headers: ["Link": evil], body: Payload.tags))
        let (tags, truncated) = try await harness.api.tags(of: repository)
        #expect(tags.count == 2 && !truncated)
        #expect(await harness.mock.requests.allSatisfy { $0.url?.host() == "api.github.com" })
    }

    @Test("A 401 triggers one refresh and a retry")
    func unauthorizedRefresh() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", .init(status: 401, body: "{}"), .init(body: Payload.repository))
        await harness.mock.on("/login/oauth/access_token", json: refreshedTokenJSON)
        _ = try await harness.api.repository(id: 42)
        let attempts = await harness.mock.requests(to: "/repositories/42")
        #expect(attempts.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer ghu_OLD", "Bearer ghu_NEW"])
    }

    @Test("A second 401 after refreshing means signing in again")
    func unauthorizedTwice() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", .init(status: 401, body: "{}"))
        await harness.mock.on("/login/oauth/access_token", json: refreshedTokenJSON)
        await #expect(throws: GitHubError.reauthorizationRequired) { try await harness.api.repository(id: 42) }
    }

    @Test("Transient server errors are retried with backoff")
    func transientRetry() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repositories/42", .init(status: 502), .init(status: 503), .init(body: Payload.repository))
        _ = try await harness.api.repository(id: 42)
        #expect(await harness.sleeps.calls == [0.5, 1.0])

        await harness.mock.on("/repos/octo/app/tags", .init(status: 500))
        await #expect(throws: GitHubError.server(status: 500)) { try await harness.api.tags(of: repository) }
        #expect(await harness.mock.requests(to: "/repos/octo/app/tags").count == 3)
    }

    @Test(
        "Errors are classified without retrying",
        arguments: [
            (404, [:], GitHubError.notFound),
            (
                403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800003600"],
                .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_003_600))
            ),
            (403, ["x-accepted-github-permissions": "contents=read"], .forbidden(neededPermission: "contents=read")),
            (422, [:], .validationFailed(message: "Bad")),
        ] as [(Int, [String: String], GitHubError)])
    func classification(status: Int, headers: [String: String], expected: GitHubError) async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", .init(status: status, headers: headers, body: #"{"message":"Bad"}"#))
        await #expect(throws: expected) { try await harness.api.repository(id: 42) }
        #expect(await harness.mock.requests.count == 1)
    }

    @Test("A short Retry-After is waited out once")
    func retryAfter() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repositories/42", .init(status: 429, headers: ["retry-after": "2"]), .init(body: Payload.repository))
        _ = try await harness.api.repository(id: 42)
        #expect(await harness.sleeps.calls.count == 1)
    }

    @Test("Being offline is reported as offline, and malformed bodies as invalid responses")
    func offlineAndMalformed() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", .init(offline: true))
        await #expect(throws: GitHubError.offline) { try await harness.api.repository(id: 42) }

        await harness.mock.on("/user", json: "[1, 2, 3]")
        await #expect(throws: GitHubError.self) { try await harness.api.currentUser() }
    }

    @Test("Installation repositories are gathered across installations, de-duplicated, and sorted")
    func installations() async throws {
        let harness = Harness()
        await harness.mock.on("/user/installations", json: #"{"installations": [{"id": 1}, {"id": 2}]}"#)
        await harness.mock.on(
            "/user/installations/1/repositories", json: #"{"repositories": [\#(Payload.repository)]}"#)
        let other = Payload.repository.replacingOccurrences(of: "\"id\": 42", with: "\"id\": 7")
            .replacingOccurrences(of: "\"name\": \"app\"", with: "\"name\": \"alpha\"")
        await harness.mock.on(
            "/user/installations/2/repositories", json: #"{"repositories": [\#(Payload.repository), \#(other)]}"#)
        let repositories = try await harness.api.installationRepositories()
        #expect(repositories.map(\.fullName) == ["octo/alpha", "octo/app"])
    }
}

@Suite("Repository sync")
struct SyncTests {
    @Test("Builds releases, tags, and unreleased changes since the latest published release")
    func fullSnapshot() async throws {
        let harness = Harness()
        let renamed = Payload.repository.replacingOccurrences(of: "\"name\": \"app\"", with: "\"name\": \"app\"")
        await harness.mock.on("/repositories/42", json: renamed)
        await harness.mock.on("/repos/octo/app/releases", json: Payload.releases)
        await harness.mock.on("/repos/octo/app/tags", json: Payload.tags)
        await harness.mock.on(
            "/repos/octo/app/compare/v1.0.0...main",
            json: Payload.compare([
                Payload.commit("c1", "Add login (#5)\n\nDetails", day: 3),
                Payload.commit("c2", "Fix crash", day: 4),
            ]))
        await harness.mock.on("/repos/octo/app/commits/c2/pulls", json: "[\(Payload.pull(6, title: "Fix crash"))]")
        await harness.mock.on(
            "/repos/octo/app/commits/c1/pulls",
            json: "[\(Payload.pull(5, title: "Add login")), \(Payload.pull(9, title: "Open", merged: false))]")

        let clock = harness.clock
        let snapshot = try await GitHubSyncService(api: harness.api, now: { clock.now }).snapshot(repositoryID: 42)

        #expect(snapshot.fetchedAt == clock.now)
        #expect(snapshot.releases.count == 3)
        #expect(snapshot.latestPublishedRelease?.tagName == "v1.0.0")
        let unreleased = try #require(snapshot.unreleased)
        #expect(unreleased.baseTag == "v1.0.0" && unreleased.headRef == "main" && unreleased.headSHA == "c2")
        #expect(unreleased.commits.map(\.sha) == ["c2", "c1"])
        #expect(unreleased.commits.map(\.pullRequestNumbers) == [[6], [5]])
        #expect(unreleased.pullRequests.map(\.number).sorted() == [5, 6])
        #expect(unreleased.pullRequestsComplete && !unreleased.isTruncated)
        #expect(snapshot.notes.isEmpty)
    }

    @Test("Without releases or tags, the latest commits are listed with a note")
    func noReleases() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", json: Payload.repository)
        await harness.mock.on("/repos/octo/app/releases", json: "[]")
        await harness.mock.on("/repos/octo/app/tags", json: "[]")
        await harness.mock.on("/repos/octo/app/commits", json: "[\(Payload.commit("c1", "Initial commit"))]")
        await harness.mock.on("/repos/octo/app/commits/c1/pulls", json: "[]")

        let snapshot = try await GitHubSyncService(api: harness.api).snapshot(repositoryID: 42)
        #expect(snapshot.unreleased?.baseTag == nil)
        #expect(snapshot.unreleased?.commits.map(\.sha) == ["c1"])
        #expect(snapshot.notes.contains { $0.contains("No releases or tags") })
    }

    @Test("A missing base tag falls back to recent commits")
    func deletedTag() async throws {
        let harness = Harness()
        await harness.mock.on("/repositories/42", json: Payload.repository)
        await harness.mock.on("/repos/octo/app/releases", json: Payload.releases)
        await harness.mock.on("/repos/octo/app/tags", json: Payload.tags)
        await harness.mock.on("/repos/octo/app/commits", json: "[\(Payload.commit("c1", "Work"))]")
        await harness.mock.on("/repos/octo/app/commits/c1/pulls", json: "[]")

        let snapshot = try await GitHubSyncService(api: harness.api).snapshot(repositoryID: 42)
        #expect(snapshot.unreleased?.baseTag == nil)
        #expect(snapshot.notes.contains { $0.contains("Couldn’t compare with v1.0.0") })
    }

    @Test("Beyond the lookup limit, pull requests are inferred from commit messages")
    func lookupLimit() async throws {
        let harness = Harness()
        let limit = GitHubSyncService.pullRequestLookupLimit
        let commits = (0...limit).map { index in
            Payload.commit("s\(index)", index == 0 ? "Old work (#77)" : "Change \(index)")
        }
        await harness.mock.on("/repositories/42", json: Payload.repository)
        await harness.mock.on("/repos/octo/app/releases", json: Payload.releases)
        await harness.mock.on("/repos/octo/app/tags", json: Payload.tags)
        await harness.mock.on("/repos/octo/app/compare/v1.0.0...main", json: Payload.compare(commits, total: 500))
        for index in 1...limit { await harness.mock.on("/repos/octo/app/commits/s\(index)/pulls", json: "[]") }

        let unreleased = try #require(
            try await GitHubSyncService(api: harness.api).snapshot(repositoryID: 42).unreleased)
        #expect(!unreleased.pullRequestsComplete && unreleased.isTruncated)
        #expect(unreleased.totalCommits == 500)
        #expect(unreleased.commits.last?.pullRequestNumbers == [77])
        #expect(await harness.mock.requests(to: "/repos/octo/app/commits/s0/pulls").isEmpty)
    }

    @Test("With tags but no releases, the highest version tag is the base")
    func baseTagSelection() {
        let tags = [
            RemoteTag(name: "v1.2.0", commitSHA: "a"), RemoteTag(name: "v1.10.0", commitSHA: "b"),
            RemoteTag(name: "nightly", commitSHA: "c"),
        ]
        #expect(GitHubSyncService.baseTag(latestRelease: nil, tags: tags) == "v1.10.0")
        #expect(GitHubSyncService.baseTag(latestRelease: nil, tags: []) == nil)
    }

    @Test("Pull request numbers are found in merge and squash commit messages")
    func references() {
        #expect(PullRequestReferences.numbers(in: "Merge pull request #12 from octo/feature\n\nBody") == [12])
        #expect(PullRequestReferences.numbers(in: "Add login (#34)") == [34])
        #expect(PullRequestReferences.numbers(in: "Fix #34 in the parser").isEmpty)
    }
}

@Suite("Snapshot cache")
struct SnapshotCacheTests {
    @Test("Snapshots round-trip; unreadable or incompatible files are ignored")
    func cache() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SnapshotCache-\(UUID().uuidString)")
        let cache = SnapshotCache(directory: directory)
        #expect(cache.load(repositoryID: 42) == nil)

        let snapshot = RepositorySnapshot(
            repository: repository, releases: [], tags: [RemoteTag(name: "v1", commitSHA: "a")], unreleased: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), notes: ["note"])
        try cache.save(snapshot)
        #expect(cache.load(repositoryID: 42) == snapshot)

        try Data("garbage".utf8).write(to: directory.appending(path: "42.json"))
        #expect(cache.load(repositoryID: 42) == nil)

        var future = snapshot
        future.format = 99
        try cache.save(future)
        #expect(cache.load(repositoryID: 42) == nil)
    }
}
