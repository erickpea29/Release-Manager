import RelvoraCore
import SwiftUI

/// The last step before a release goes public: shows the draft exactly as GitHub has it now. Publishing is a click,
/// never the Return key, because it can't be undone from Relvora.
struct PublishReleaseSheet: View {
    let release: ReleaseModel
    let preview: PublishPreview

    @Environment(\.dismiss) private var dismiss
    @State private var isPublishing = false
    @State private var errorMessage: String?

    private var draft: RemoteRelease { preview.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Publish Release").font(.title2.bold())
                Text(
                    "Relvora publishes this draft on GitHub. Everyone who can see the repository can see the "
                        + "release, and workflows that run on published releases start, such as one that builds "
                        + "and attaches your app. A published release can’t be turned back into a draft from Relvora."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                FactRow(label: "Repository") { Text(preview.repository.fullName).bold() }
                FactRow(label: "Tag") {
                    HStack(spacing: Spacing.xs) {
                        Text(draft.tagName).font(.body.monospaced().bold())
                        Text(tagNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                FactRow(label: "Target commit") {
                    Text(draft.targetCommitish).font(.callout.monospaced().bold()).textSelection(.enabled)
                }
                FactRow(label: "Title") { Text(draft.name ?? draft.tagName) }
                FactRow(label: "Pre-release") { Text(draft.isPrerelease ? "Yes" : "No") }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Release notes").font(.headline)
                    if preview.notesEditedOnGitHub {
                        Text("Edited on GitHub since Relvora created the draft.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                ScrollView {
                    if (draft.body ?? "").isBlank {
                        Text("No release notes.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownPreview(markdown: draft.body ?? "")
                    }
                }
                .frame(height: 200)
                .panel(padding: Spacing.s)
            }

            ForEach(preview.problemMessages, id: \.self) { message in
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.canPublish {
                Text("Fix the draft on GitHub, or delete it there, choose Check Publication, and create a new draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isPublishing {
                    ProgressView().controlSize(.small)
                    Text("Publishing…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isPublishing)
                Button("Publish Release") { Task { await publish() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPublishing || !preview.canPublish)
            }
        }
        .padding(Spacing.l)
        .frame(width: 580)
        .interactiveDismissDisabled(isPublishing)
    }

    private var tagNote: String {
        switch preview.existingTagCommitSHA {
        case nil: "New. GitHub creates it at this commit."
        case draft.targetCommitish?: "Already exists at this commit; GitHub uses it."
        case let sha?: "Already exists, at \(sha.prefix(7))."
        }
    }

    private func publish() async {
        isPublishing = true
        defer { isPublishing = false }
        switch await release.publish(preview) {
        case .success: dismiss()
        case .failure(let error): errorMessage = AppAlert.message(for: error)
        }
    }
}
