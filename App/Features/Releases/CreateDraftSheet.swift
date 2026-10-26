import RelvoraCore
import SwiftUI

/// The last step before anything is written to GitHub: shows exactly what the draft will contain.
struct CreateDraftSheet: View {
    let release: ReleaseModel
    @State var review: ReleaseReview
    let check: ReleaseCheck

    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var warnings: [ReleaseIssue] {
        check.issues.filter { $0.severity != .blocking && !isIncompleteTasks($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Create GitHub Draft").font(.title2.bold())
                Text(
                    "Relvora creates a draft release. Nothing is published, and the tag isn’t created until you "
                        + "publish the draft, here or on GitHub."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                FactRow(label: "Repository") { Text(review.repositoryFullName).bold() }
                FactRow(label: "Tag") {
                    HStack(spacing: Spacing.xs) {
                        Text(review.tagName).font(.body.monospaced().bold())
                        Text(tagNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                FactRow(label: "Target commit") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(review.targetCommitSHA).font(.callout.monospaced().bold()).textSelection(.enabled)
                        if let commit = release.targetCommit {
                            Text(commit.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if let branch = review.targetBranch { FactRow(label: "Branch") { Text(branch) } }
                FactRow(label: "Title") { Text(review.releaseName) }
                FactRow(label: "Pre-release") { Text(review.isPrerelease ? "Yes" : "No") }
                if !release.workspace.releaseSteps.isEmpty {
                    FactRow(label: "Checklist") {
                        Label(
                            "All \(release.workspace.releaseSteps.count) steps done",
                            systemImage: "checkmark.square.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Release notes").font(.headline)
                ScrollView {
                    if review.notes.isBlank {
                        Text("No release notes.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownPreview(markdown: review.notes)
                    }
                }
                .frame(height: 200)
                .panel(padding: Spacing.s)
            }

            ForEach(warnings) { IssueRow(issue: $0) }
            if check.incompleteTaskCount > 0 {
                let count = check.incompleteTaskCount
                Toggle(isOn: $review.confirmsIncompleteTasks) {
                    Text(
                        "Create the draft although \(count) \(count == 1 ? "task isn’t" : "tasks aren’t") complete. "
                            + "Tasks are not changed.")
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text("Creating the draft…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create Draft") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isCreating || !check.allowsDraft(confirmingIncompleteTasks: review.confirmsIncompleteTasks))
            }
        }
        .padding(Spacing.l)
        .frame(width: 580)
        .interactiveDismissDisabled(isCreating)
    }

    private var tagNote: String {
        check.issues.contains { if case .tagExistsAtTarget = $0.kind { true } else { false } }
            ? "Already exists at this commit; GitHub uses it."
            : "New. GitHub creates it at this commit when you publish."
    }

    private func isIncompleteTasks(_ issue: ReleaseIssue) -> Bool {
        if case .incompleteTasks = issue.kind { true } else { false }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        switch await release.createDraft(review) {
        case .success:
            dismiss()
        case .failure(let error as ReleaseWorkflowError) where error == .outcomeUnknown || isNotSaved(error):
            // The plan's reconciliation panel explains what happens next; keeping the sheet open would invite a
            // retry. Only a failed local save needs its own message.
            if isNotSaved(error) { release.errorMessage = AppAlert.message(for: error) }
            dismiss()
        case .failure(let error):
            errorMessage = AppAlert.message(for: error)
        }
    }

    private func isNotSaved(_ error: ReleaseWorkflowError) -> Bool {
        if case .draftNotSaved = error { true } else { false }
    }
}
