import Foundation
import Testing

@testable import RelvoraCore

@Suite("Commit graph")
struct CommitGraphTests {
    private func commit(_ sha: String, _ parents: [String], _ message: String = "Change") -> RemoteCommit {
        RemoteCommit(
            sha: sha, message: message, authorName: nil, authorLogin: "ann", date: nil,
            htmlURL: URL(string: "https://github.com/octo/app/commit/\(sha)")!, parentSHAs: parents)
    }

    @Test("A straight history stays on one lane and leads to the base")
    func straight() {
        let graph = CommitGraph.layout([commit("c3", ["c2"]), commit("c2", ["c1"]), commit("c1", ["v1"])])
        #expect(graph.laneCount == 1)
        #expect(graph.rows.map(\.lane) == [0, 0, 0])
        #expect(graph.rows.map(\.incoming) == [[], [0], [0]])
        #expect(graph.rows.map(\.outgoing) == [[0], [0], [0]])
        #expect(graph.openLanes == [0])
    }

    @Test("A merged branch gets its own lane, named after the merge, and joins where it started")
    func mergedBranch() {
        let graph = CommitGraph.layout([
            commit("m", ["a", "b"], "Merge pull request #14 from octo/drafts\n\nCreate drafts"),
            commit("b", ["x"]),
            commit("a", ["x"]),
            commit("x", ["v1"]),
        ])
        #expect(graph.laneCount == 2)
        #expect(graph.rows.map(\.lane) == [0, 1, 0, 0])
        #expect(graph.rows[0].outgoing == [0, 1])
        #expect(graph.rows[1].passing == [0])
        #expect(graph.rows[2].passing == [1])
        #expect(graph.rows[3].incoming == [0, 1], "Both lanes end in the commit the branch started from")
        #expect(graph.rows.map(\.branch) == [nil, "drafts", nil, nil])
        #expect(graph.openLanes == [0])
    }

    @Test("Parents outside the commits shown lead to the base")
    func truncated() {
        let graph = CommitGraph.layout([commit("m", ["a", "older"]), commit("a", ["v1"])])
        #expect(graph.rows[0].outgoing == [0, 1])
        #expect(graph.openLanes == [0, 1])
    }

    @Test("Commits without parents, from an older cache, follow each other")
    func withoutParents() {
        let graph = CommitGraph.layout([commit("c2", []), commit("c1", [])])
        #expect(graph.rows.map(\.lane) == [0, 0])
        #expect(graph.rows[1].incoming == [0])
        #expect(graph.openLanes == [0])
        #expect(CommitGraph.layout([]).laneCount == 1)
    }

    @Test("Merge messages name their branch")
    func branchNames() {
        #expect(CommitGraph.mergedBranch("Merge pull request #14 from octo/drafts\n\nBody") == "drafts")
        #expect(CommitGraph.mergedBranch("Merge pull request #2 from octo/feature/login") == "feature/login")
        #expect(CommitGraph.mergedBranch("Merge branch 'release/0.2' into main") == "release/0.2")
        #expect(CommitGraph.mergedBranch("Merge remote-tracking branch 'origin/main'") == "origin/main")
        #expect(CommitGraph.mergedBranch("Fix the merge button") == nil)
    }

    @Test("The size bar splits five squares between additions and deletions")
    func squares() {
        #expect(ChangeStats(additions: 482, deletions: 37, changedFiles: 9).squares == (4, 1, 0))
        #expect(ChangeStats(additions: 10, deletions: 0, changedFiles: 1).squares == (5, 0, 0))
        #expect(ChangeStats(additions: 0, deletions: 5, changedFiles: 1).squares == (0, 5, 0))
        #expect(ChangeStats(additions: 1, deletions: 100, changedFiles: 2).squares == (1, 4, 0))
        #expect(ChangeStats(additions: 0, deletions: 0, changedFiles: 1).squares == (0, 0, 5))
    }

    @Test("Commits cached before 0.2.5, without parents, still load")
    func olderCache() throws {
        let json = #"""
            {"sha": "c1", "message": "Fix", "htmlURL": "https://github.com/octo/app/commit/c1",
             "pullRequestNumbers": [3]}
            """#
        let decoded = try JSONDecoder().decode(RemoteCommit.self, from: Data(json.utf8))
        #expect(decoded.parentSHAs.isEmpty && decoded.pullRequestNumbers == [3])
        let roundTrip = try JSONDecoder().decode(
            RemoteCommit.self, from: JSONEncoder().encode(commit("c2", ["c1"])))
        #expect(roundTrip.parentSHAs == ["c1"])
    }
}

@Suite("Release brief: commits")
struct ReleaseBriefCommitsTests {
    private func facts(commits: [String]) -> ReleaseBriefFacts {
        ReleaseBriefFacts(
            version: "0.2.5", title: nil, plannedDate: nil, tasks: [], attention: [], checklistDone: 0,
            checklistTotal: 0, hasTargetCommit: true, targetCI: nil, isCheckedOnGitHub: false,
            commitSummaries: commits, baseTag: "v0.2.4")
    }

    @Test("The prompt lists the commits since the last release, at most 20")
    func prompt() {
        let prompt = ReleaseBriefComposer.prompt(facts(commits: (1...25).map { "Commit \($0)" }))
        #expect(prompt.contains("COMMITS since v0.2.4 (newest first):\n- Commit 1\n"))
        #expect(prompt.contains("- Commit 20\n…and 5 more"))
        #expect(!ReleaseBriefComposer.prompt(facts(commits: [])).contains("COMMITS"))
    }

    @Test("The changes title is used only when there are commits")
    func changesTitle() {
        let composition = ReleaseBriefComposition(changesTitle: "  Faster sign-in  ")
        let withCommits = ReleaseBriefComposer.resolve(composition, facts: facts(commits: ["Fix"]), isComplete: true)
        #expect(withCommits.changesTitle == "Faster sign-in")
        let without = ReleaseBriefComposer.resolve(composition, facts: facts(commits: []), isComplete: true)
        #expect(without.changesTitle == nil)
        #expect(ReleaseBriefComposer.standard(facts(commits: ["Fix"])).changesTitle == nil)
    }

    @Test("New commits change the fingerprint, so the brief is written again")
    func fingerprint() {
        #expect(facts(commits: ["Fix"]).fingerprint != facts(commits: ["Fix", "Add"]).fingerprint)
    }
}
