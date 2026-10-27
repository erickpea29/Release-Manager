import AppKit
import RelvoraCore
import SwiftUI

/// A commit's CI: always an icon and words, never color alone.
struct CIStatusLabel: View {
    let status: CIStatus?
    /// Says whose CI it is, such as "On main".
    var prefix: String?

    var body: some View {
        Label {
            Text([prefix, status?.title ?? "CI unknown"].compactMap(\.self).joined(separator: ": "))
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private var symbol: String {
        switch status {
        case .passed?: "checkmark.circle.fill"
        case .failed?: "xmark.circle.fill"
        case .running?: "clock.fill"
        case .notReported?: "minus.circle"
        case nil: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .passed?: .green
        case .failed?: .red
        case .running?: .orange
        case .notReported?, nil: .secondary
        }
    }
}

/// Open and recently merged pull requests of a repository, with their CI and Merge… (ADR 0020). Refreshes when shown,
/// and every minute while shown and Relvora is the active app.
struct PullRequestList: View {
    @Environment(AppModel.self) private var app
    let connection: RepositoryConnection
    /// Only pull requests into this branch; every branch when `nil`.
    let base: String?
    /// Branches whose latest commit's CI matters here, such as the release's branch.
    let branches: [String]
    var onMerged: (PullRequest, String) -> Void = { _, _ in }

    @State private var merging: PullRequest?

    static let refreshInterval: TimeInterval = 60

    private var model: PullRequestModel { app.pullRequests }
    private var repositoryID: Int64 { connection.githubRepositoryID }
    private var state: PullRequestModel.Repository { model.state(repositoryID) }
    private var open: [PullRequest] { state.open.filter { base == nil || $0.baseRef == base } }
    private var merged: [PullRequest] { state.merged.filter { base == nil || $0.baseRef == base } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            status
            if state.fetchedAt != nil, open.isEmpty {
                Text(base.map { "No open pull requests into \($0)." } ?? "No open pull requests.")
                    .foregroundStyle(.secondary)
            }
            ForEach(open) { pull in
                OpenPullRequestRow(
                    pull: pull, ci: model.ci(pull.headSHA, in: repositoryID),
                    readiness: model.readiness(pull, in: repositoryID), showsBase: base == nil
                ) { merging = pull }
                if pull.id != open.last?.id { Divider() }
            }
            if !merged.isEmpty {
                Text("Merged recently")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.xs)
                ForEach(merged) { pull in
                    MergedPullRequestRow(pull: pull, ci: pull.mergeCommitSHA.flatMap { model.ci($0, in: repositoryID) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(repositoryID) \(branches)") { await keepFresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh(maxAge: 15) }
        }
        .sheet(item: $merging) { pull in
            MergePullRequestSheet(pull: pull, connection: connection) { sha in
                onMerged(pull, sha)
                Task { await model.refresh(repositoryID: repositoryID, branches: branches) }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let problem = model.ciProblems[repositoryID] {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = state.error {
            Label("Couldn’t load pull requests. \(error)", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if state.fetchedAt == nil {
            HStack(spacing: Spacing.xs) {
                if app.github.isConnected { ProgressView().controlSize(.small) }
                Text(app.github.isConnected ? "Loading pull requests…" : "Connect GitHub to see pull requests.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func keepFresh() async {
        await refresh(maxAge: 20)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
            if NSApplication.shared.isActive { await refresh(maxAge: Self.refreshInterval - 10) }
        }
    }

    private func refresh(maxAge: TimeInterval) async {
        await model.refreshIfStale(repositoryID: repositoryID, branches: branches, maxAge: maxAge)
    }
}

/// An open pull request: its branches, CI, whether it can merge, and Merge….
struct OpenPullRequestRow: View {
    let pull: PullRequest
    let ci: CIStatus?
    let readiness: MergeReadiness
    var showsBase = false
    let merge: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text("#\(pull.number)")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(pull.title)
                    if pull.isDraft { LabelChip(text: "Draft") }
                }
                HStack(spacing: Spacing.xs) {
                    Text(showsBase ? "\(pull.headRef) → \(pull.baseRef)" : pull.headRef)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let author = pull.authorLogin { Text("· @\(author)") }
                    if let updated = pull.updatedAt { Text("· \(updated.formatted(.relative(presentation: .named)))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: Spacing.s) {
                    CIStatusLabel(status: ci)
                    if showsReadiness {
                        Text(readiness.summary)
                            .foregroundStyle(readiness == .ready ? .primary : .secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button("Merge…", action: merge)
                .disabled(!readiness.canMerge)
                .help(readiness.canMerge ? "Merge #\(pull.number) into \(pull.baseRef)" : readiness.summary)
                .accessibilityIdentifier("merge-\(pull.number)")
            GitHubLinkIcon(url: pull.htmlURL, label: "Open pull request on GitHub")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pullRequest-\(pull.number)")
    }

    /// CI says why it can't merge in those cases; the rest are said here.
    private var showsReadiness: Bool {
        ![.ciFailed, .waitingForCI, .ciUnknown, .notOpen].contains(readiness)
    }
}

/// A recently merged pull request, with CI on the commit the merge created.
struct MergedPullRequestRow: View {
    let pull: PullRequest
    let ci: CIStatus?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.purple)
                .accessibilityLabel("Merged")
            Text("#\(pull.number)")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pull.title)
                HStack(spacing: Spacing.xs) {
                    if let merged = pull.mergedAt {
                        Text("Merged \(merged.formatted(.relative(presentation: .named)))")
                    }
                    if let sha = pull.mergeCommitSHA { Text("as \(sha.prefix(7))").monospaced() }
                    CIStatusLabel(status: ci, prefix: "On \(pull.baseRef)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            GitHubLinkIcon(url: pull.htmlURL, label: "Open pull request on GitHub")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mergedPullRequest-\(pull.number)")
    }
}

/// Confirms a merge: exactly the commit shown, with the chosen method. The only GitHub write outside releasing.
struct MergePullRequestSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pull: PullRequest
    let connection: RepositoryConnection
    let onMerged: (String) -> Void

    @State private var method = MergeMethod.merge
    @State private var isMerging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Merge #\(pull.number) into \(pull.baseRef)?").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                FactRow(label: "Pull request") { Text(pull.title).fixedSize(horizontal: false, vertical: true) }
                FactRow(label: "Repository") { Text(connection.fullName) }
                FactRow(label: "From") {
                    Text("\(pull.headRef) at \(pull.headSHA.prefix(7))").textSelection(.enabled)
                }
                FactRow(label: "Into") { Text(pull.baseRef) }
                FactRow(label: "CI") { CIStatusLabel(status: app.pullRequests.ci(pull.headSHA, in: repositoryID)) }
                FactRow(label: "Method") {
                    Picker("Method", selection: $method) {
                        ForEach(MergeMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            Text(
                "GitHub merges exactly \(pull.headSHA.prefix(7)), the commit shown here. If the branch got new commits "
                    + "since, GitHub refuses and nothing is merged. The repository’s settings may not allow every method."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Open on GitHub", destination: pull.htmlURL)
                Spacer()
                if isMerging { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge Pull Request") { Task { await merge() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isMerging)
            }
        }
        .padding(Spacing.l)
        .frame(width: 500)
        .onAppear { method = app.preferences.mergeMethod }
    }

    private var repositoryID: Int64 { connection.githubRepositoryID }

    private func merge() async {
        isMerging = true
        defer { isMerging = false }
        do {
            let sha = try await app.pullRequests.merge(pull, method: method, in: repositoryID)
            app.preferences.mergeMethod = method
            onMerged(sha)
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
