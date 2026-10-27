import Foundation
import Testing

@testable import RelvoraCore

@Suite("Pull requests and CI")
struct PullRequestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ name: String, _ conclusion: String?) -> CheckRun {
        CheckRun(name: name, isCompleted: conclusion != nil, conclusion: conclusion, htmlURL: nil)
    }

    private func pull(
        _ number: Int, state: PullRequest.State = .open, draft: Bool = false, base: String = "main",
        mergedDaysAgo: Double? = nil
    ) -> PullRequest {
        let mergedAt = mergedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return PullRequest(
            number: number, title: "Change \(number)", authorLogin: "erick", state: state, isDraft: draft,
            headRef: "feature/\(number)", headSHA: "head\(number)", baseRef: base, mergedAt: mergedAt,
            mergeCommitSHA: mergedAt == nil ? nil : "merge\(number)", updatedAt: now,
            htmlURL: URL(string: "https://github.com/octo/app/pull/\(number)")!)
    }

    private func commit(_ sha: String) -> RemoteCommit {
        RemoteCommit(
            sha: sha, message: "Commit \(sha)\n\nDetails", authorName: nil, authorLogin: nil, date: nil,
            htmlURL: URL(string: "https://github.com/octo/app/commit/\(sha)")!)
    }

    @Test("CI is summarized from its checks: a failure shows at once, neutral and skipped checks pass")
    func ciStatus() {
        #expect(CIStatus([]) == .notReported)
        #expect(
            CIStatus([run("Build", "success"), run("Docs", "skipped"), run("Lint", "neutral")]) == .passed(total: 3))
        #expect(CIStatus([run("Build", "success"), run("UI tests", nil)]) == .running(finished: 1, total: 2))
        let failed = CIStatus([run("Build", nil), run("UI tests", "failure"), run("UI tests", "timed_out")])
        #expect(failed == .failed(checks: ["UI tests"], total: 3))
        #expect(failed.title == "CI failed: UI tests")
        #expect(CIStatus([run("Build", "cancelled")]).outcome == .failed)
        #expect(CIStatus([run("Build", "success"), run("UI tests", nil)]).outcome == nil)

        let many = CIStatus([run("A", "failure"), run("B", "failure"), run("C", "failure"), run("D", "failure")])
        #expect(many.failingChecks == "A, B, and 2 more")
        #expect(CIStatus([run("A", "failure"), run("B", "failure")]).failingChecks == "A and B")
        #expect(CIStatus.running(finished: 1, total: 2).title == "CI running (1 of 2 done)")
    }

    @Test("Merging is offered only when CI passed and GitHub says it can merge")
    func readiness() {
        let clean = Mergeability(isMergeable: true, state: "clean")
        let open = pull(15)
        #expect(MergeReadiness.of(open, ci: .passed(total: 2), mergeability: clean) == .ready)
        #expect(MergeReadiness.of(open, ci: .notReported, mergeability: clean) == .ready)
        #expect(
            MergeReadiness.of(open, ci: .passed(total: 2), mergeability: .init(isMergeable: true, state: "has_hooks"))
                == .ready)
        #expect(MergeReadiness.of(pull(15, draft: true), ci: .passed(total: 2), mergeability: clean) == .draft)
        #expect(
            MergeReadiness.of(open, ci: .passed(total: 2), mergeability: .init(isMergeable: false, state: "dirty"))
                == .conflicts)
        #expect(MergeReadiness.of(open, ci: .failed(checks: ["UI tests"], total: 2), mergeability: clean) == .ciFailed)
        #expect(MergeReadiness.of(open, ci: .running(finished: 0, total: 2), mergeability: clean) == .waitingForCI)
        #expect(MergeReadiness.of(open, ci: nil, mergeability: clean) == .ciUnknown)
        #expect(
            MergeReadiness.of(open, ci: .passed(total: 1), mergeability: .init(isMergeable: true, state: "behind"))
                == .behind)
        #expect(
            MergeReadiness.of(open, ci: .passed(total: 1), mergeability: .init(isMergeable: true, state: "blocked"))
                == .blocked)
        #expect(MergeReadiness.of(open, ci: .passed(total: 1), mergeability: nil) == .checking)
        #expect(
            MergeReadiness.of(open, ci: .passed(total: 1), mergeability: .init(isMergeable: nil, state: "unknown"))
                == .checking)
        #expect(MergeReadiness.of(pull(15, state: .merged), ci: .passed(total: 1), mergeability: clean) == .notOpen)
        #expect(MergeReadiness.ready.canMerge && !MergeReadiness.waitingForCI.canMerge)
    }

    @Test("Recently merged: the last few days, newest first, into the release's branch")
    func recentlyMerged() {
        let pulls = [
            pull(10, state: .merged, mergedDaysAgo: 1), pull(11, state: .merged, mergedDaysAgo: 0.1),
            pull(12, state: .merged, mergedDaysAgo: 5), pull(13, state: .closed),
            pull(14, state: .merged, base: "release/0.1", mergedDaysAgo: 0.5), pull(15),
        ]
        #expect(PullRequestRules.recentlyMerged(pulls, into: "main", now: now).map(\.number) == [11, 10])
        #expect(PullRequestRules.recentlyMerged(pulls, into: nil, now: now).map(\.number) == [11, 14, 10])
        let many = (1...8).map { pull($0, state: .merged, mergedDaysAgo: Double($0) / 10) }
        #expect(PullRequestRules.recentlyMerged(many, into: "main", now: now).count == 5)
    }

    @Test("The suggested release commit is the newest one whose CI passed")
    func latestPassing() {
        let commits = ["c3", "c2", "c1", "c0"].map(commit)
        let ci: [String: CIStatus] = [
            "c3": .running(finished: 0, total: 2), "c2": .failed(checks: ["Build"], total: 1), "c0": .passed(total: 2),
        ]
        #expect(PullRequestRules.latestPassing(commits, ci: ci)?.sha == "c0")
        #expect(PullRequestRules.latestPassing(commits, ci: ["c3": .passed(total: 1)])?.sha == "c3")
        #expect(PullRequestRules.latestPassing(commits, ci: [:]) == nil)
    }

    @Test("Finished CI is announced once, never what had finished before Relvora was watching")
    func newlyFinished() {
        let passed = CIRun(
            subject: .pullRequest(number: 15, title: "Change", baseRef: "main"), sha: "aaa", status: .passed(total: 2))
        let running = CIRun(
            subject: .branch("main", commitSummary: "Merge"), sha: "bbb", status: .running(finished: 0, total: 2))
        #expect(PullRequestRules.newlyFinished([passed, running], known: nil).isEmpty)
        #expect(PullRequestRules.newlyFinished([passed, running], known: []) == [passed])
        #expect(PullRequestRules.newlyFinished([passed], known: [passed.key!]).isEmpty)
        // A failed check run again and passing is a new outcome on the same commit.
        let failed = CIRun(
            subject: .pullRequest(number: 15, title: "Change", baseRef: "main"), sha: "aaa",
            status: .failed(checks: ["UI tests"], total: 2))
        #expect(PullRequestRules.newlyFinished([passed], known: [failed.key!]) == [passed])
    }

    @Test("CI notifications say what's ready, what failed, and open the release plan")
    func notifications() throws {
        let projectID = UUID()
        func content(_ run: CIRun, version: String? = "0.2.3") -> NotificationContent? {
            AppNotifications.ciFinished(
                run, projectID: projectID, projectName: "Relvora", repository: "octo/app", version: version)
        }
        let pullRequest = CIRun.Subject.pullRequest(number: 15, title: "Pull requests in Relvora", baseRef: "main")
        let ready = try #require(
            content(CIRun(subject: pullRequest, sha: "a", status: .passed(total: 2), readiness: .ready)))
        #expect(ready.title == "#15 is ready to merge")
        #expect(
            ready.body
                == "CI passed on “Pull requests in Relvora” in octo/app. You can merge it into main from Relvora.")
        #expect(ready.kind == .ciFinished && ready.target == .project(projectID, tab: "releases"))

        let blocked = try #require(
            content(CIRun(subject: pullRequest, sha: "a", status: .passed(total: 2), readiness: .blocked)))
        #expect(blocked.title == "CI passed on #15")
        #expect(blocked.body.hasSuffix("Blocked by the branch’s rules, such as a required review."))

        let failed = try #require(
            content(CIRun(subject: pullRequest, sha: "a", status: .failed(checks: ["UI tests"], total: 2))))
        #expect(failed.title == "CI failed on #15")
        #expect(failed.body == "UI tests failed on “Pull requests in Relvora” in octo/app.")

        let main = CIRun.Subject.branch("main", commitSummary: "Merge pull request #15")
        let branch = try #require(content(CIRun(subject: main, sha: "abcdef123", status: .passed(total: 2))))
        #expect(branch.title == "main is ready for Relvora 0.2.3")
        #expect(branch.body.hasPrefix("CI passed at abcdef1 “Merge pull request #15” in octo/app."))
        #expect(
            content(CIRun(subject: main, sha: "abcdef123", status: .passed(total: 2)), version: nil)?.title
                == "CI passed on main")
        let broken = try #require(
            content(CIRun(subject: main, sha: "abcdef123", status: .failed(checks: ["Lint"], total: 2))))
        #expect(broken.title == "CI failed on main")
        #expect(content(CIRun(subject: main, sha: "abcdef123", status: .running(finished: 1, total: 2))) == nil)
        #expect(ready.id != failed.id)
    }
}
