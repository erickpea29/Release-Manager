import Foundation
import RelvoraCore
import Testing

@Suite("Changelog")
struct ChangelogTests {
    private let projectID = UUID()
    private let columnID = UUID()
    private let repositoryURL = URL(string: "https://github.com/octo/app")!

    private func task(_ title: String, _ type: TaskType, done: Bool = true, day: Int = 1) -> ProjectTask {
        ProjectTask(
            projectID: projectID, columnID: columnID, title: title, type: type, sortOrder: 1,
            completedAt: done ? Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400) : nil)
    }

    private func pull(_ number: Int, _ title: String, labels: [String] = [], author: String? = "bob")
        -> RemotePullRequest
    {
        RemotePullRequest(
            number: number, title: title, authorLogin: author, mergedAt: .now, labels: labels,
            htmlURL: repositoryURL.appending(path: "pull/\(number)"))
    }

    private func commit(_ sha: String, _ message: String, pulls: [Int] = []) -> RemoteCommit {
        RemoteCommit(
            sha: sha + String(repeating: "0", count: 40 - sha.count), message: message, authorName: "Ann",
            authorLogin: "ann", date: nil, htmlURL: repositoryURL.appending(path: "commit/\(sha)"),
            pullRequestNumbers: pulls)
    }

    private func changes(
        commits: [RemoteCommit], pulls: [RemotePullRequest], base: String? = "v1.0.0", truncated: Bool = false,
        complete: Bool = true
    ) -> UnreleasedChanges {
        UnreleasedChanges(
            baseTag: base, headRef: "main", headSHA: commits.first?.sha,
            totalCommits: commits.count + (truncated ? 5 : 0),
            commits: commits, pullRequests: pulls, isTruncated: truncated, pullRequestsComplete: complete,
            compareURL: nil)
    }

    @Test("Groups tasks by type and pull requests by label or prefix, with a compare link")
    func grouping() {
        let input = ChangelogInput(
            tasks: [
                task("Drag columns", .feature, day: 2),
                task("Faster board", .improvement),
                task("Unfinished work", .feature, done: false),
            ],
            changes: changes(
                commits: [
                    commit("ccc", "fix(ui): Typo in header"),
                    commit("bbb", "Merge pull request #7 from octo/login\n\nAdd login screen", pulls: [7]),
                    commit("aaa", "Squashed (#6)", pulls: [6]),
                ],
                pulls: [
                    pull(7, "feat: add login screen", labels: []),
                    pull(6, "Crash on launch", labels: ["bug", "priority: high"]),
                    pull(8, "Bump swift-format", labels: ["dependencies"], author: "dependabot[bot]"),
                ]),
            tagName: "v1.1.0", repositoryURL: repositoryURL)

        let markdown = ChangelogGenerator.markdown(input)
        #expect(
            markdown == """
                ## Features

                - Drag columns
                - Add login screen (#7) by @bob

                ## Improvements

                - Faster board

                ## Bug Fixes

                - Crash on launch (#6) by @bob
                - Typo in header (ccc0000)

                ## Maintenance

                - Bump swift-format (#8) by @dependabot[bot]

                **Full changelog:** https://github.com/octo/app/compare/v1.0.0...v1.1.0

                """)
        // Deterministic: the same input gives the same text.
        #expect(ChangelogGenerator.markdown(input) == markdown)
    }

    @Test("A task with the same title as a pull request is listed once")
    func deduplication() {
        let input = ChangelogInput(
            tasks: [task("Add login screen.", .feature)],
            changes: changes(commits: [], pulls: [pull(7, "feat: Add login screen")]),
            tagName: nil, repositoryURL: nil)
        #expect(ChangelogGenerator.entries(input).map(\.text) == ["Add login screen (#7) by @bob"])
    }

    @Test("Breaking changes come first; unlabeled changes go to Other")
    func breakingAndOther() {
        let input = ChangelogInput(
            tasks: [],
            changes: changes(
                commits: [commit("ddd", "Rename settings keys"), commit("eee", "Merge branch 'main' into dev")],
                pulls: [pull(9, "feat(api)!: Drop v1 endpoints")]),
            tagName: nil, repositoryURL: nil)
        let entries = ChangelogGenerator.entries(input)
        #expect(entries.map(\.category) == [.breaking, .other])
        #expect(entries.map(\.text) == ["Drop v1 endpoints (#9) by @bob", "Rename settings keys (ddd0000)"])
    }

    @Test("Options leave out tasks, pull requests, or commits")
    func options() {
        let input = ChangelogInput(
            tasks: [task("Local work", .other)],
            changes: changes(commits: [commit("fff", "docs: Readme")], pulls: [pull(3, "Something")]),
            tagName: nil, repositoryURL: nil)
        #expect(
            ChangelogGenerator.entries(input, options: .init(includeTasks: false, includeCommits: false)).map(\.text)
                == ["Something (#3) by @bob"])
        #expect(
            ChangelogGenerator.entries(input, options: .init(includePullRequests: false)).map(\.category)
                == [.other, .documentation])
    }

    @Test("Missing data is reported as warnings")
    func warnings() {
        let partial = ChangelogInput(
            tasks: [task("Open", .feature, done: false)],
            changes: changes(commits: [commit("aaa", "x")], pulls: [], base: nil, truncated: true, complete: false),
            tagName: nil, repositoryURL: nil)
        let warnings = ChangelogGenerator.warnings(partial)
        #expect(warnings.count == 4)
        #expect(warnings.first == "1 task isn’t complete and was left out.")

        let tasksOnly = ChangelogInput(tasks: [], changes: nil, tagName: nil, repositoryURL: nil)
        #expect(ChangelogGenerator.warnings(tasksOnly) == ["No GitHub changes were loaded, so only tasks are listed."])
        #expect(ChangelogGenerator.markdown(tasksOnly).isEmpty)
    }

    @Test(
        "Labels map to sections",
        arguments: [
            ("bug", ChangelogCategory.fixes), ("type: bug", .fixes), ("enhancement", .features),
            ("Documentation", .documentation), ("docs", .documentation), ("dependencies", .maintenance),
            ("performance", .improvements), ("breaking-change", .breaking),
        ])
    func labels(label: String, expected: ChangelogCategory) {
        #expect(ChangelogGenerator.category(labels: [label], title: "Anything") == expected)
    }

    @Test("Labels that mean nothing fall back to the title prefix, then to no category")
    func fallback() {
        #expect(ChangelogGenerator.category(labels: ["needs review"], title: "perf: Cache images") == .improvements)
        #expect(ChangelogGenerator.category(labels: [], title: "Cache images") == nil)
        // The strongest label wins regardless of order.
        #expect(ChangelogGenerator.category(labels: ["docs", "bug"], title: "x") == .fixes)
    }
}
