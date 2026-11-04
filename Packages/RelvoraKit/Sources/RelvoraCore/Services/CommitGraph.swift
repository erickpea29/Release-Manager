import Foundation

/// A release's commits drawn as a graph (ADR 0025): each commit on a lane, with lines to the commits it follows. Like
/// `git log --graph`, newest first; a lane keeps its column for as long as it runs, so lines never cross.
public struct CommitGraph: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let sha: String
        /// The commit's lane.
        public let lane: Int
        /// Lanes that end in this commit, from the row above: its own lane, and lanes of branches that started here.
        public let incoming: [Int]
        /// Lanes that leave this commit for the row below: one per parent.
        public let outgoing: [Int]
        /// Lanes that pass this row without touching the commit.
        public let passing: [Int]
        /// The branch this commit was the tip of, when a merge below says so ("feature/login").
        public let branch: String?

        public var id: String { sha }
    }

    public let rows: [Row]
    /// Lanes still open below the last row. They lead to the base: the last release, or older commits not shown.
    public let openLanes: [Int]
    public let laneCount: Int

    /// Where a parent outside the commits shown leads: the base row.
    static let base = "\u{0}base"

    /// Lays out `commits`, newest first. Parents outside them lead to the base; a commit without parents (an older
    /// cache) follows the next one, so the graph is a straight line.
    public static func layout(_ commits: [RemoteCommit]) -> CommitGraph {
        let shown = Set(commits.map(\.sha))
        let branches = branchTips(commits)
        var lanes: [String?] = []
        var rows: [Row] = []
        var width = 0

        for (index, commit) in commits.enumerated() {
            let incoming = lanes.indices.filter { lanes[$0] == commit.sha }
            let lane = incoming.first ?? lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
            if lane == lanes.count { lanes.append(nil) }
            let passing = lanes.indices.filter { lanes[$0] != nil && !incoming.contains($0) }
            for slot in incoming { lanes[slot] = nil }

            let next = index + 1 < commits.count ? commits[index + 1].sha : base
            let parents =
                commit.parentSHAs.isEmpty ? [next] : commit.parentSHAs.map { shown.contains($0) ? $0 : base }
            var outgoing: [Int] = []
            for (position, parent) in parents.enumerated() {
                let slot: Int
                if position == 0 {
                    slot = lane
                } else if let waiting = lanes.firstIndex(where: { $0 == parent }) {
                    slot = waiting
                } else {
                    slot = lanes.indices.first { lanes[$0] == nil && $0 != lane } ?? lanes.count
                    if slot == lanes.count { lanes.append(nil) }
                }
                lanes[slot] = parent
                if !outgoing.contains(slot) { outgoing.append(slot) }
            }
            width = max(width, lanes.count)
            rows.append(
                Row(
                    sha: commit.sha, lane: lane, incoming: incoming, outgoing: outgoing,
                    passing: passing, branch: branches[commit.sha]))
        }
        let open = lanes.indices.filter { lanes[$0] != nil }
        return CommitGraph(rows: rows, openLanes: open, laneCount: max(width, 1))
    }

    /// The branch each merged branch's tip commit came from, read from its merge commit's message.
    static func branchTips(_ commits: [RemoteCommit]) -> [String: String] {
        var tips: [String: String] = [:]
        for commit in commits where commit.parentSHAs.count > 1 {
            if let branch = mergedBranch(commit.message) { tips[commit.parentSHAs[1]] = branch }
        }
        return tips
    }

    /// The branch a merge commit's message names: GitHub's "Merge pull request #14 from octo/login" gives "login",
    /// and Git's "Merge branch 'feature/x' into main" gives "feature/x".
    public static func mergedBranch(_ message: String) -> String? {
        let summary = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if let match = summary.firstMatch(of: /^Merge pull request #\d+ from ([^\s]+)/) {
            let ref = String(match.1)
            // "owner/branch/with/slashes": the owner is the first part.
            guard let slash = ref.firstIndex(of: "/") else { return ref }
            return String(ref[ref.index(after: slash)...])
        }
        if let match = summary.firstMatch(of: /^Merge (?:remote-tracking )?branch '([^']+)'/) {
            return String(match.1)
        }
        return nil
    }
}
