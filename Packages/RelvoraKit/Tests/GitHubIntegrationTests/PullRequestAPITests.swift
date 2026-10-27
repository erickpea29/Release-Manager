import Foundation
import RelvoraCore
import Testing

@testable import GitHubIntegration

@Suite("Pull requests and CI API")
struct PullRequestAPITests {
    private let repository = GitHubRepository(
        id: 42, owner: "octo", name: "app", defaultBranch: "main",
        htmlURL: URL(string: "https://github.com/octo/app")!, isPrivate: true)

    private static func pull(
        _ number: Int, state: String = "open", draft: Bool = false, merged: Bool = false, extra: String = ""
    ) -> String {
        """
        {"number": \(number), "title": "Change \(number)", "html_url": "https://github.com/octo/app/pull/\(number)",
         "state": "\(state)", "draft": \(draft), "merged_at": \(merged ? "\"2026-10-26T10:00:00Z\"" : "null"),
         "merge_commit_sha": "m\(number)", "updated_at": "2026-10-26T11:00:00Z", "user": {"login": "erick"},
         "labels": [], "head": {"ref": "feature/\(number)", "sha": "h\(number)"}, "base": {"ref": "main"}\(extra)}
        """
    }

    @Test("Open and closed pull requests are listed with their branches; merged ones keep their merge commit")
    func lists() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/pulls", json: "[\(Self.pull(15)), \(Self.pull(16, draft: true))]")
        let open = try await harness.api.openPullRequests(of: repository)
        #expect(open.map(\.number) == [15, 16])
        #expect(open[0].state == .open && !open[0].isDraft && open[1].isDraft)
        #expect(open[0].headRef == "feature/15" && open[0].headSHA == "h15" && open[0].baseRef == "main")
        #expect(open[0].mergeCommitSHA == nil, "An open pull request's merge commit is only GitHub's test merge")
        let sent = try #require(await harness.mock.requests(to: "/repos/octo/app/pulls").first)
        let query = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "state", value: "open")))
        #expect(query.contains(URLQueryItem(name: "sort", value: "updated")))

        let closed = Harness()
        await closed.mock.on(
            "/repos/octo/app/pulls",
            json: "[\(Self.pull(13, state: "closed", merged: true)), \(Self.pull(12, state: "closed"))]")
        let pulls = try await closed.api.closedPullRequests(of: repository)
        #expect(pulls.map(\.state) == [.merged, .closed])
        #expect(pulls[0].mergeCommitSHA == "m13" && pulls[0].mergedAt != nil && pulls[1].mergeCommitSHA == nil)
    }

    @Test("One pull request comes with whether GitHub can merge it")
    func mergeability() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/pulls/15", json: Self.pull(15, extra: #", "mergeable": true, "mergeable_state": "clean""#))
        await harness.mock.on("/repos/octo/app/pulls/16", json: Self.pull(16, extra: #", "mergeable": null"#))
        let ready = try await harness.api.pullRequest(of: repository, number: 15)
        #expect(ready.pullRequest.number == 15)
        #expect(ready.mergeability == Mergeability(isMergeable: true, state: "clean"))
        let computing = try await harness.api.pullRequest(of: repository, number: 16)
        #expect(computing.mergeability == Mergeability(isMergeable: nil, state: "unknown"))
    }

    @Test("Check runs are read per commit; without the Checks permission GitHub answers 403")
    func checkRuns() async throws {
        let harness = Harness()
        await harness.mock.on(
            "/repos/octo/app/commits/h15/check-runs",
            json: """
                {"total_count": 2, "check_runs": [
                  {"name": "Lint, test, and build", "status": "completed", "conclusion": "success",
                   "html_url": "https://github.com/octo/app/runs/1"},
                  {"name": "UI tests", "status": "in_progress", "conclusion": null, "html_url": null}]}
                """)
        let runs = try await harness.api.checkRuns(of: repository, sha: "h15")
        #expect(runs.map(\.name) == ["Lint, test, and build", "UI tests"])
        #expect(CIStatus(runs) == .running(finished: 1, total: 2))
        let sent = try #require(await harness.mock.requests(to: "/repos/octo/app/commits/h15/check-runs").first)
        #expect(sent.url?.query()?.contains("filter=latest") == true)

        let denied = Harness()
        await denied.mock.on(
            "/repos/octo/app/commits/h15/check-runs",
            .init(
                status: 403, headers: ["x-accepted-github-permissions": "checks=read"],
                body: #"{"message": "Resource not accessible by integration"}"#))
        await #expect(throws: GitHubError.forbidden(neededPermission: "checks=read")) {
            try await denied.api.checkRuns(of: repository, sha: "h15")
        }
    }

    @Test("Merging sends the head commit it was shown, once; GitHub's refusals come back as they are")
    func merge() async throws {
        let harness = Harness()
        await harness.mock.on(
            "PUT /repos/octo/app/pulls/15/merge",
            .init(body: #"{"sha": "m15", "merged": true, "message": "Pull Request successfully merged"}"#))
        let sha = try await harness.api.mergePullRequest(in: repository, number: 15, headSHA: "h15", method: .squash)
        #expect(sha == "m15")
        let sent = try #require(await harness.mock.requests(to: "/repos/octo/app/pulls/15/merge", method: "PUT").first)
        let body = try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: String]
        #expect(body == ["sha": "h15", "merge_method": "squash"])

        let refused = Harness()
        await refused.mock.on(
            "PUT /repos/octo/app/pulls/15/merge",
            .init(status: 405, body: #"{"message": "At least 1 approving review is required by reviewers."}"#))
        await #expect(throws: GitHubError.refused(message: "At least 1 approving review is required by reviewers.")) {
            try await refused.api.mergePullRequest(in: repository, number: 15, headSHA: "h15", method: .merge)
        }

        let moved = Harness()
        await moved.mock.on(
            "PUT /repos/octo/app/pulls/15/merge",
            .init(status: 409, body: #"{"message": "Head branch was modified. Review and try the merge again."}"#))
        await #expect(throws: GitHubError.conflict) {
            try await moved.api.mergePullRequest(in: repository, number: 15, headSHA: "h15", method: .merge)
        }

        let lost = Harness()
        await lost.mock.on("PUT /repos/octo/app/pulls/15/merge", .init(failure: .timedOut))
        await #expect(throws: GitHubError.timedOut) {
            try await lost.api.mergePullRequest(in: repository, number: 15, headSHA: "h15", method: .merge)
        }
        #expect(await lost.mock.requests(to: "/repos/octo/app/pulls/15/merge").count == 1, "A write is sent once")
    }
}
