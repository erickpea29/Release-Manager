import RelvoraCore
import SwiftUI

/// Everything a release snapshot recorded: target, links, notes, tasks, and pull requests. Read-only.
struct SnapshotDetailView: View {
    let snapshot: ReleaseSnapshot
    var projectName: String?

    @State private var showsPublishedNotes = true
    @State private var exportedNotes: MarkdownFile?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            facts
            notes
            if !snapshot.tasks.isEmpty { tasks }
            if let pullRequests = snapshot.changes?.pullRequests, !pullRequests.isEmpty {
                pullRequestList(pullRequests)
            }
        }
        .fileExporter(
            isPresented: $isExporting, document: exportedNotes, contentType: MarkdownFile.markdown,
            defaultFilename: "Release notes \(snapshot.version)"
        ) { _ in exportedNotes = nil }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                if let projectName { FactRow(label: "Project") { Text(projectName) } }
                FactRow(label: "Repository") { Text(snapshot.repositoryFullName) }
                FactRow(label: "Tag") {
                    HStack(spacing: Spacing.xs) {
                        Text(snapshot.effectiveTagName).font(.body.monospaced())
                        if snapshot.publishedTagName != nil {
                            Text("reviewed as \(snapshot.tagName)").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                FactRow(label: "Commit") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.effectiveCommitSHA).font(.callout.monospaced()).textSelection(.enabled)
                        if let published = snapshot.publishedCommitSHA, published != snapshot.targetCommitSHA {
                            Text("Reviewed commit: \(snapshot.targetCommitSHA)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let branch = snapshot.targetBranch { FactRow(label: "Branch") { Text(branch) } }
                FactRow(label: "Title on GitHub") { Text(snapshot.releaseName) }
                if snapshot.isPrerelease { FactRow(label: "Type") { Text("Pre-release") } }
                FactRow(label: snapshot.origin == .external ? "Recorded" : "Draft requested") {
                    Text(snapshot.snapshotCreatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let publishedAt = snapshot.publishedAt {
                    FactRow(label: "Published") {
                        Text(publishedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let changes = snapshot.changes {
                    FactRow(label: "Changes") {
                        Text(
                            "\(changes.totalCommits) \(changes.totalCommits == 1 ? "commit" : "commits"), "
                                + "\(changes.pullRequests.count) pull requests"
                                + (changes.baseTag.map { " since \($0)" } ?? "")
                                + (changes.isComplete ? "" : " (partial)"))
                    }
                }
            }
            .font(.callout)
            links
        }
        .panel()
    }

    private var links: some View {
        HStack(spacing: Spacing.m) {
            if let url = snapshot.githubReleaseURL {
                Link(destination: url) {
                    Label(snapshot.state == .published ? "Release" : "Draft", systemImage: "arrow.up.right.square")
                }
            }
            Link(destination: snapshot.commitURL) { Label("Commit", systemImage: "arrow.up.right.square") }
            if snapshot.state == .published {
                Link(destination: snapshot.tagURL) { Label("Tag", systemImage: "arrow.up.right.square") }
            }
            if let compare = snapshot.changes?.compareURL {
                Link(destination: compare) { Label("Compare", systemImage: "arrow.up.right.square") }
            }
            Spacer()
        }
        .font(.callout)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Release Notes").font(.headline)
                Spacer()
                if snapshot.publishedNotesMarkdown != nil {
                    Picker("Version", selection: $showsPublishedNotes) {
                        Text("As published").tag(true)
                        Text("As submitted").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    exportedNotes = MarkdownFile(text: shownNotes)
                    isExporting = true
                }
                .disabled(shownNotes.isEmpty)
            }
            if snapshot.publishedNotesMarkdown != nil {
                Text("The notes were edited on GitHub before publishing. Both versions are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if shownNotes.isEmpty {
                Text("No release notes.").foregroundStyle(.secondary)
            } else {
                MarkdownPreview(markdown: shownNotes)
            }
        }
        .panel()
    }

    private var shownNotes: String {
        showsPublishedNotes ? snapshot.effectiveNotesMarkdown : snapshot.releaseNotesMarkdown
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            let done = snapshot.tasks.filter(\.isCompleted).count
            Text("Tasks").font(.headline)
            Text(
                "\(done) of \(snapshot.tasks.count) complete when the snapshot was taken. Later edits don’t change this list."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(snapshot.tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isCompleted ? .green : .secondary)
                        .accessibilityLabel(task.isCompleted ? "Complete" : "Not complete")
                    Image(systemName: task.type.symbol)
                        .foregroundStyle(.secondary)
                        .help(task.type.title)
                    Text(task.title)
                    Spacer()
                    ForEach(task.labels.prefix(3), id: \.self) { LabelChip(text: $0) }
                    if let column = task.columnName {
                        Text(column).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }

    private func pullRequestList(_ pullRequests: [RemotePullRequest]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Pull Requests").font(.headline)
            ForEach(pullRequests) { pullRequest in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("#\(pullRequest.number)").font(.body.monospaced()).foregroundStyle(.secondary)
                    Text(pullRequest.title)
                    Spacer()
                    if let author = pullRequest.authorLogin {
                        Text("@\(author)").font(.caption).foregroundStyle(.secondary)
                    }
                    Link(destination: pullRequest.htmlURL) { Image(systemName: "arrow.up.right.square") }
                        .help("Open pull request on GitHub")
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }
}
