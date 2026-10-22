import Foundation
import RelvoraCore
import Testing

@testable import GitHubIntegration

private let repository = GitHubRepository(
    id: 42, owner: "octo", name: "app", defaultBranch: "main",
    htmlURL: URL(string: "https://github.com/octo/app")!, isPrivate: true)
private let sha = String(repeating: "a", count: 40)
private let request = DraftReleaseRequest(
    tagName: "v1.1.0", targetCommitSHA: sha, name: "1.1.0 – Login", body: "## Features\n- Login", isPrerelease: true)

@Suite("Release API")
struct ReleaseAPITests {
    @Test("Creating a draft posts the reviewed tag, commit, and notes as a draft")
    func createDraft() async throws {
        let harness = Harness()
        await harness.mock.on(
            "POST /repos/octo/app/releases", .init(status: 201, body: Payload.release(9, tag: "v1.1.0", draft: true)))
        let release = try await harness.api.createDraftRelease(in: repository, request)
        #expect(release.id == 9 && release.isDraft)

        let sent = try #require(await harness.mock.requests(to: "/repos/octo/app/releases", method: "POST").first)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try #require(sent.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["tag_name"] as? String == "v1.1.0")
        #expect(body["target_commitish"] as? String == sha)
        #expect(body["name"] as? String == "1.1.0 – Login")
        #expect(body["body"] as? String == "## Features\n- Login")
        #expect(body["draft"] as? Bool == true)
        #expect(body["prerelease"] as? Bool == true)
        #expect(body["generate_release_notes"] as? Bool == false)
    }

    @Test(
        "A failed create is sent once and classified by whether GitHub may have acted on it",
        arguments: [
            (MockGitHub.Response(status: 502), true),
            (MockGitHub.Response(failure: .timedOut), true),
            (MockGitHub.Response(failure: .networkConnectionLost), true),
            (MockGitHub.Response(status: 201, body: "{\"unexpected\": true}"), true),
            (MockGitHub.Response(offline: true), false),
            (MockGitHub.Response(status: 403, body: #"{"message":"Resource not accessible by integration"}"#), false),
            (MockGitHub.Response(status: 422, body: #"{"message":"Validation Failed"}"#), false),
        ])
    func failedCreate(response: MockGitHub.Response, mayHaveCreated: Bool) async throws {
        let harness = Harness()
        await harness.mock.on("POST /repos/octo/app/releases", response)
        let result = await GitHubReleaseRemote(api: harness.api).createDraftRelease(in: repository, request)
        switch result {
        case .created: Issue.record("Nothing should have been created")
        case .unknown: #expect(mayHaveCreated)
        case .rejected: #expect(!mayHaveCreated)
        }
        #expect(await harness.mock.requests(to: "/repos/octo/app/releases", method: "POST").count == 1)
        #expect(await harness.sleeps.calls.isEmpty)
    }

    @Test("GitHub's validation details are part of the message")
    func validationDetails() async throws {
        let harness = Harness()
        let body = #"""
            {"message":"Validation Failed","errors":[{"resource":"Release","code":"already_exists","field":"tag_name"}]}
            """#
        await harness.mock.on("POST /repos/octo/app/releases", .init(status: 422, body: body))
        await #expect(throws: GitHubError.validationFailed(message: "Validation Failed (tag_name already_exists)")) {
            try await harness.api.createDraftRelease(in: repository, request)
        }
    }

    @Test("A 401 on create is repeated once with a refreshed token, because GitHub rejected it unread")
    func unauthorizedCreate() async throws {
        let harness = Harness()
        await harness.mock.on(
            "POST /repos/octo/app/releases", .init(status: 401),
            .init(status: 201, body: Payload.release(9, tag: "v1.1.0", draft: true)))
        await harness.mock.on("/login/oauth/access_token", json: refreshedTokenJSON)
        _ = try await harness.api.createDraftRelease(in: repository, request)
        let attempts = await harness.mock.requests(to: "/repos/octo/app/releases", method: "POST")
        #expect(attempts.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer ghu_OLD", "Bearer ghu_NEW"])
    }

    @Test("Reads still retry dropped connections")
    func readRetry() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/releases/9", .init(failure: .networkConnectionLost),
            .init(body: Payload.release(9, tag: "v1.1.0", draft: false)))
        let release = try await harness.api.release(of: repository, id: 9)
        #expect(release.publishedAt != nil && !release.isDraft)
        #expect(await harness.sleeps.calls == [0.5])
    }

    @Test("Tags resolve through annotated tag objects; a missing tag is nil")
    func tags() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/git/ref/tags/release/1.0", json: #"{"object": {"type": "tag", "sha": "t1"}}"#)
        await harness.mock.on("/repos/octo/app/git/tags/t1", json: #"{"object": {"type": "commit", "sha": "c1"}}"#)
        await harness.mock.on(
            "/repos/octo/app/git/ref/tags/v1.0.0", json: #"{"object": {"type": "commit", "sha": "c0"}}"#)
        #expect(try await harness.api.tagCommitSHA(of: repository, tag: "release/1.0") == "c1")
        #expect(try await harness.api.tagCommitSHA(of: repository, tag: "v1.0.0") == "c0")
        #expect(try await harness.api.tagCommitSHA(of: repository, tag: "v9.9.9") == nil)
    }

    @Test("A deleted release reads as nil; other failures still throw")
    func deletedRelease() async throws {
        let harness = Harness()
        let remote = GitHubReleaseRemote(api: harness.api)
        #expect(try await remote.release(of: repository, id: 77) == nil)
        await harness.mock.on("/repos/octo/app/releases/78", .init(status: 403, body: "{}"))
        await #expect(throws: GitHubError.self) { try await remote.release(of: repository, id: 78) }
    }

    @Test("Branches, single commits, and changes up to a target commit")
    func branchesCommitsAndChanges() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/branches",
            json: #"[{"name": "main", "commit": {"sha": "m1"}}, {"name": "release", "commit": {"sha": "r1"}}]"#)
        #expect(try await harness.api.branches(of: repository).items.map(\.name) == ["main", "release"])

        await harness.mock.on("/repos/octo/app/commits/abc1234", json: Payload.commit(sha, "Fix crash"))
        #expect(try await harness.api.commit(of: repository, ref: "abc1234").sha == sha)

        await harness.mock.on(
            "/repos/octo/app/compare/v1.0.0...\(sha)",
            json: Payload.compare([Payload.commit("c1", "Add login (#5)"), Payload.commit(sha, "Fix crash")]))
        await harness.mock.on("/repos/octo/app/commits/\(sha)/pulls", json: "[\(Payload.pull(6, title: "Fix crash"))]")
        await harness.mock.on(
            "/repos/octo/app/commits/c1/pulls", json: "[\(Payload.pull(5, title: "Add login", base: "develop"))]")
        let (changes, notes) = try await GitHubSyncService(api: harness.api).changes(
            in: repository, base: "v1.0.0", head: sha, branch: "main")
        #expect(changes.headSHA == sha && changes.headRef == sha && notes.isEmpty)
        // Only pull requests merged into the release branch count.
        #expect(changes.pullRequests.map(\.number) == [6])
    }
}
