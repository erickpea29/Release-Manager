import RelvoraCore
import SwiftUI

/// What's in the release (ADR 0025): Apple Intelligence's title for the changes, the commits since the last release as
/// a graph with branch lanes, open pull requests waiting at the top, and how much the release changes.
struct ReleaseChangesCard: View {
    @Environment(AppModel.self) private var app
    let release: ReleaseModel

    static let maximumRows = 12
    static let maximumPending = 3
    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 14

    var body: some View {
        if let plan = release.plan {
            VStack(alignment: .leading, spacing: Spacing.s) {
                header(plan)
                content(plan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What’s in this release")
            .accessibilityIdentifier("releaseChanges")
            .task(id: release.currentChangesKey) {
                if release.currentChangesKey != nil, app.github.isConnected { await release.loadChanges() }
            }
        }
    }

    /// The model's title for the commits, when it wrote one; otherwise the plan's own.
    private func title(_ plan: ReleasePlan) -> String {
        let written = release.briefFacts.flatMap { app.briefs.brief(for: plan.id, facts: $0).changesTitle }
        return written ?? plan.title ?? "Changes in \(plan.version)"
    }

    private func header(_ plan: ReleasePlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(plan))
                    .font(.headline)
                    .accessibilityIdentifier("releaseChangesTitle")
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let stats = release.currentChanges?.stats { DiffStatChip(stats: stats) }
        }
    }

    private var subtitle: String {
        guard let changes = release.currentChanges else { return "What’s in this release" }
        let commits = "\(changes.totalCommits) \(changes.totalCommits == 1 ? "commit" : "commits")"
        let since = changes.baseTag.map { " since \($0)" } ?? ""
        let pulls = changes.pullRequests.count
        return commits + since + (pulls == 0 ? "" : " · \(pulls) pull \(pulls == 1 ? "request" : "requests") merged")
    }

    @ViewBuilder
    private func content(_ plan: ReleasePlan) -> some View {
        if plan.targetCommitSHA == nil {
            Text("Choose the commit to release to see what’s in it.").foregroundStyle(.secondary)
        } else if let changes = release.currentChanges {
            graph(changes, plan: plan)
        } else if let error = release.changesError {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
        } else if !app.github.isConnected {
            Text("Connect GitHub in Settings to see what’s in this release.").foregroundStyle(.secondary)
        } else {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Reading the changes…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The graph

    @ViewBuilder
    private func graph(_ changes: UnreleasedChanges, plan: ReleasePlan) -> some View {
        let shown = Array(changes.commits.prefix(Self.maximumRows))
        let graph = CommitGraph.layout(shown)
        let pending = openPullRequests(plan)
        let lanes = graph.laneCount
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pending.enumerated()), id: \.element.number) { index, pull in
                row(.pending(isFirst: index == 0), lanes: lanes) { pendingContent(pull) }
            }
            ForEach(Array(zip(graph.rows, shown).enumerated()), id: \.element.0.sha) { index, item in
                let (graphRow, commit) = item
                row(.commit(graphRow, pendingAbove: index == 0 && !pending.isEmpty), lanes: lanes) {
                    commitContent(
                        commit, lane: graphRow.lane,
                        branch: index == 0 ? plan.targetBranch ?? changes.headRef : graphRow.branch)
                }
            }
            row(.base(open: graph.openLanes), lanes: lanes) { baseContent(changes) }
        }
        let hidden = changes.totalCommits - shown.count
        if hidden > 0 || changes.compareURL != nil {
            HStack(spacing: Spacing.m) {
                if hidden > 0 {
                    Text("…and \(hidden) more \(hidden == 1 ? "commit" : "commits")").foregroundStyle(.secondary)
                }
                Spacer()
                if let url = changes.compareURL {
                    Link(destination: url) { Label("View the Comparison", systemImage: "arrow.up.right.square") }
                }
            }
            .font(.callout)
        }
    }

    private func row(_ kind: CommitGraphCell.Kind, lanes: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Spacing.s) {
            CommitGraphCell(kind: kind)
                .frame(width: CGFloat(lanes) * Self.laneWidth, height: Self.rowHeight)
                .accessibilityHidden(true)
            content()
        }
        .frame(height: Self.rowHeight)
    }

    private func commitContent(_ commit: RemoteCommit, lane: Int, branch: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(commit.summary).lineLimit(1).truncationMode(.tail)
            if let branch { BranchChip(name: branch, lane: lane) }
            Spacer(minLength: Spacing.s)
            Text(commit.shortSHA).font(.callout.monospaced()).foregroundStyle(.secondary)
            Text(byline(login: commit.authorLogin, name: commit.authorName, date: commit.date))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitRow")
    }

    private func pendingContent(_ pull: PullRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("#\(pull.number) \(pull.title)").foregroundStyle(.secondary).lineLimit(1)
            BranchChip(name: pull.headRef, lane: nil)
            Spacer(minLength: Spacing.s)
            if let connection = release.connection {
                CIStatusLabel(status: app.pullRequests.ci(pull.headSHA, in: connection.githubRepositoryID))
                    .font(.callout)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open pull request #\(pull.number), \(pull.title), not merged yet")
        .accessibilityIdentifier("pendingPullRequestRow")
    }

    private func baseContent(_ changes: UnreleasedChanges) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            if let base = changes.baseTag {
                BranchChip(name: base, lane: nil)
                Text("Last release").foregroundStyle(.secondary)
            } else {
                Text("The repository’s earlier commits").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Open, non-draft pull requests into the release's branch: work not in the release yet.
    private func openPullRequests(_ plan: ReleasePlan) -> [PullRequest] {
        guard let connection = release.connection, let branch = plan.targetBranch ?? connection.defaultBranch else {
            return []
        }
        return Array(
            app.pullRequests.state(connection.githubRepositoryID).open
                .filter { $0.baseRef == branch && !$0.isDraft }
                .prefix(Self.maximumPending))
    }

    private func byline(login: String?, name: String?, date: Date?) -> String {
        let author = login.map { "@\($0)" } ?? name
        return [author, date.map { Self.ago($0) }].compactMap(\.self).joined(separator: " · ")
    }

    /// "now", "25m", "2h", "3d", then a date: short enough for a row.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// A branch or tag name on a commit row, tinted like its lane; the words stay full strength.
private struct BranchChip: View {
    let name: String
    /// The lane it's drawn on; `nil` for names off the graph (a pull request's branch, the base tag).
    let lane: Int?

    var body: some View {
        Text(name)
            .font(.callout.monospaced())
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(lane.map { CommitGraphCell.style($0) } ?? AnyShapeStyle(Color.secondary))
                    .opacity(0.14)
            }
            .fixedSize()
    }
}

/// One row's slice of the graph. Rows are the same height, so the slices join into continuous lines.
struct CommitGraphCell: View {
    enum Kind {
        /// A commit; `pendingAbove` draws the dashed line from open pull requests into the newest commit.
        case commit(CommitGraph.Row, pendingAbove: Bool)
        /// An open pull request, not merged: a hollow dot on the main lane, dashed.
        case pending(isFirst: Bool)
        /// The last release, where the lanes still open end.
        case base(open: [Int])
    }

    let kind: Kind

    /// Lane 0 is the release's branch, in the app's accent; branches take the next colors.
    static func style(_ lane: Int) -> AnyShapeStyle {
        let palette: [Color] = [.green, .orange, .purple, .pink, .teal]
        return lane == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(palette[(lane - 1) % palette.count])
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let bottom = size.height
            func x(_ lane: Int) -> CGFloat { ReleaseChangesCard.laneWidth * (CGFloat(lane) + 0.5) }
            func line(from start: CGPoint, to end: CGPoint, lane: Int, dashed: Bool = false) {
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let middle = (start.y + end.y) / 2
                    path.addCurve(
                        to: end, control1: CGPoint(x: start.x, y: middle), control2: CGPoint(x: end.x, y: middle))
                }
                context.stroke(
                    path, with: .style(Self.style(lane)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [2, 3] : []))
            }
            func dot(_ lane: Int, color: AnyShapeStyle, hollow: Bool = false) {
                let rect = CGRect(x: x(lane) - 3.5, y: mid - 3.5, width: 7, height: 7)
                if hollow {
                    context.stroke(
                        Path(ellipseIn: rect), with: .style(color),
                        style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 1.5]))
                } else {
                    context.fill(Path(ellipseIn: rect), with: .style(color))
                }
            }

            switch kind {
            case .commit(let row, let pendingAbove):
                let here = CGPoint(x: x(row.lane), y: mid)
                for lane in row.passing {
                    line(from: CGPoint(x: x(lane), y: 0), to: CGPoint(x: x(lane), y: bottom), lane: lane)
                }
                for lane in row.incoming {
                    // A branch that started here is drawn in its own color as it bends in.
                    line(from: CGPoint(x: x(lane), y: 0), to: here, lane: lane)
                }
                if row.incoming.isEmpty && pendingAbove {
                    line(from: CGPoint(x: x(row.lane), y: 0), to: here, lane: row.lane, dashed: true)
                }
                for lane in row.outgoing {
                    line(from: here, to: CGPoint(x: x(lane), y: bottom), lane: max(lane, row.lane))
                }
                dot(row.lane, color: Self.style(row.lane))
            case .pending(let isFirst):
                if !isFirst {
                    line(from: CGPoint(x: x(0), y: 0), to: CGPoint(x: x(0), y: mid - 4), lane: 0, dashed: true)
                }
                line(from: CGPoint(x: x(0), y: mid + 4), to: CGPoint(x: x(0), y: bottom), lane: 0, dashed: true)
                dot(0, color: AnyShapeStyle(.secondary), hollow: true)
            case .base(let open):
                for lane in open { line(from: CGPoint(x: x(lane), y: 0), to: CGPoint(x: x(0), y: mid), lane: lane) }
                dot(0, color: AnyShapeStyle(.secondary))
            }
        }
    }
}
