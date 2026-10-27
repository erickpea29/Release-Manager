import AppKit
import GitHubIntegration
import RelvoraCore
import SwiftUI

/// One connected repository: sync status (fresh vs. cached), pull requests, unreleased changes, releases, and tags.
struct RepositoryDetailView: View {
    enum Section: String, CaseIterable, Identifiable {
        case pullRequests = "Pull Requests"
        case unreleased = "Unreleased"
        case releases = "Releases"
        case tags = "Tags"
        var id: Self { self }
    }

    @Environment(AppModel.self) private var app
    let connection: RepositoryConnection
    let model: WorkspaceModel
    @State private var section = Section.pullRequests

    private var github: GitHubModel { app.github }
    private var snapshot: RepositorySnapshot? { github.snapshot(for: connection.githubRepositoryID) }
    private var syncState: GitHubModel.SyncState { github.syncState(for: connection.githubRepositoryID) }
    private var refreshInterval: GitHubRefreshInterval { app.preferences.githubRefresh }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            syncStatus
            if let notes = snapshot?.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(connection.id) \(refreshInterval.rawValue)") { await keepFresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshIfDue() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(connection.fullName)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                HStack(spacing: Spacing.s) {
                    if connection.isPrivate { Label("Private", systemImage: "lock") }
                    if let branch = connection.defaultBranch { Label(branch, systemImage: "arrow.triangle.branch") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: connection.htmlURL) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(syncState == .refreshing || !github.isConnected)
                .keyboardShortcut("r", modifiers: .command)
                .help(
                    refreshInterval.seconds == nil
                        ? "Refresh from GitHub (⌘R)"
                        : "Refresh from GitHub now (⌘R). Relvora also refreshes \(refreshInterval.title.lowercased()).")
        }
    }

    /// Always says whether the data shown is fresh or cached, and from when.
    @ViewBuilder
    private var syncStatus: some View {
        switch syncState {
        case .refreshing:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(snapshot == nil ? "Loading from GitHub…" : "Refreshing from GitHub… (showing cached data)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    snapshot.map { "Couldn’t refresh. Showing cached data from \(Self.describe($0.fetchedAt))." }
                        ?? "Couldn’t load this repository.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
        case .idle:
            if let snapshot {
                // Re-rendered every 30 seconds, so "Synced … ago" stays current between refreshes.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let isStale = context.date.timeIntervalSince(snapshot.fetchedAt) > 3600
                    Label(
                        isStale
                            ? "Cached data from \(Self.describe(snapshot.fetchedAt))"
                            : "Synced \(Self.describe(snapshot.fetchedAt))" + automaticNote,
                        systemImage: isStale ? "clock.arrow.circlepath" : "checkmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(isStale ? .orange : .secondary)
                }
            } else if !github.isConnected {
                Label("Connect GitHub to load this repository.", systemImage: "link")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if section == .pullRequests {
            // Read live from GitHub, apart from the repository snapshot (ADR 0020).
            ScrollView {
                PullRequestList(
                    connection: connection, base: nil, branches: [connection.defaultBranch].compactMap(\.self)
                ) { _, _ in
                    Task { await refresh() }
                }
                .padding(.vertical, Spacing.xs)
            }
        } else if let snapshot {
            switch section {
            case .pullRequests: EmptyView()
            case .unreleased: unreleased(snapshot)
            case .releases: releases(snapshot)
            case .tags: tags(snapshot)
            }
        } else if syncState != .refreshing {
            ContentUnavailableView(
                "No Data Yet", systemImage: "icloud.and.arrow.down",
                description: Text("Refresh to load releases, tags, and unreleased changes."))
        } else {
            Spacer()
        }
    }

    @ViewBuilder
    private func unreleased(_ snapshot: RepositorySnapshot) -> some View {
        if let changes = snapshot.unreleased {
            List {
                SwiftUI.Section {
                    HStack {
                        Text(
                            "\(changes.totalCommits) \(changes.totalCommits == 1 ? "commit" : "commits") on \(changes.headRef) "
                                + (changes.baseTag.map { "since \($0)" } ?? "(no previous release)"))
                        Spacer()
                        if let url = changes.compareURL { Link("Compare on GitHub", destination: url) }
                    }
                }
                if !changes.pullRequests.isEmpty {
                    SwiftUI.Section("Merged pull requests (\(changes.pullRequests.count))") {
                        ForEach(changes.pullRequests) { PullRequestRow(pullRequest: $0) }
                    }
                }
                SwiftUI.Section("Commits") {
                    if changes.commits.isEmpty {
                        Text("Nothing new since \(changes.baseTag ?? "the last release").").foregroundStyle(.secondary)
                    }
                    ForEach(changes.commits) { CommitRow(commit: $0) }
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView(
                "No Unreleased Changes", systemImage: "checkmark.circle",
                description: Text("Unreleased changes appear once the repository has a default branch."))
        }
    }

    @ViewBuilder
    private func releases(_ snapshot: RepositorySnapshot) -> some View {
        if snapshot.releases.isEmpty {
            ContentUnavailableView(
                "No Releases", systemImage: "shippingbox", description: Text("Nothing published yet."))
        } else {
            let latest = snapshot.latestPublishedRelease?.id
            List(snapshot.releases) { release in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(release.tagName).font(.body.monospaced().weight(.semibold))
                    if let name = release.name { Text(name).foregroundStyle(.secondary) }
                    if release.id == latest { ReleaseFlag(text: "Latest", tint: .green) }
                    if release.isDraft { ReleaseFlag(text: "Draft", tint: .blue) }
                    if release.isPrerelease { ReleaseFlag(text: "Pre-release", tint: .orange) }
                    Spacer()
                    Text(Self.describe(release.publishedAt ?? release.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GitHubLinkIcon(url: release.htmlURL, label: "Open release on GitHub")
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func tags(_ snapshot: RepositorySnapshot) -> some View {
        if snapshot.tags.isEmpty {
            ContentUnavailableView("No Tags", systemImage: "tag", description: Text("This repository has no tags yet."))
        } else {
            List(snapshot.tags, id: \.name) { tag in
                HStack {
                    Label(tag.name, systemImage: "tag").font(.body.monospaced())
                    Spacer()
                    Text(String(tag.commitSHA.prefix(7)))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.inset)
        }
    }

    private var automaticNote: String {
        refreshInterval.seconds == nil ? "" : " · refreshes \(refreshInterval.title.lowercased())"
    }

    private func refresh() async {
        if let remote = await github.refresh(repositoryID: connection.githubRepositoryID) {
            await model.recordSync(of: connection, remote: remote)
        }
    }

    /// Loads the repository the first time it is shown, then keeps it fresh on the chosen interval while it is shown
    /// and Relvora is the active app (Settings › GitHub).
    private func keepFresh() async {
        if snapshot == nil && github.isConnected { await refresh() }
        guard refreshInterval.seconds != nil else { return }
        while !Task.isCancelled {
            await refreshIfDue()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func refreshIfDue() async {
        guard let interval = refreshInterval.seconds, NSApplication.shared.isActive,
            github.isRefreshDue(repositoryID: connection.githubRepositoryID, interval: interval)
        else { return }
        await refresh()
    }

    static func describe(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

private struct ReleaseFlag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct PullRequestRow: View {
    let pullRequest: RemotePullRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text("#\(pullRequest.number)")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pullRequest.title)
                HStack(spacing: Spacing.xs) {
                    if let author = pullRequest.authorLogin { Text("@\(author)") }
                    if let merged = pullRequest.mergedAt { Text("merged \(RepositoryDetailView.describe(merged))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(pullRequest.labels.prefix(3), id: \.self) { LabelChip(text: $0) }
            GitHubLinkIcon(url: pullRequest.htmlURL, label: "Open pull request on GitHub")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CommitRow: View {
    let commit: RemoteCommit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(commit.shortSHA)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary).lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    if let author = commit.authorLogin.map({ "@\($0)" }) ?? commit.authorName { Text(author) }
                    if let date = commit.date { Text(RepositoryDetailView.describe(date)) }
                    if !commit.pullRequestNumbers.isEmpty {
                        Text(commit.pullRequestNumbers.map { "#\($0)" }.joined(separator: ", "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            GitHubLinkIcon(url: commit.htmlURL, label: "Open commit on GitHub")
        }
        .accessibilityElement(children: .combine)
    }
}
