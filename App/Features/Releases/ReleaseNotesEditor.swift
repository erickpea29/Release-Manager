import RelvoraCore
import SwiftUI

/// The release notes: generate from tasks and GitHub, edit as Markdown, preview, and export.
/// Edits are saved shortly after typing stops (by `ReleaseModel`), and kept through any GitHub failure.
struct ReleaseNotesEditor: View {
    private enum Mode: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
    }

    @Bindable var release: ReleaseModel
    @State private var mode = Mode.edit
    @State private var generated: String?
    @State private var isGenerating = false
    @State private var exportedNotes: MarkdownFile?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionTitle("Release Notes", detail: "Markdown, as it will appear on GitHub.")
                Spacer()
                if isGenerating || release.isLoadingChanges { ProgressView().controlSize(.small) }
                Menu {
                    Toggle("Completed Tasks", isOn: $release.changelogOptions.includeTasks)
                    Toggle("Merged Pull Requests", isOn: $release.changelogOptions.includePullRequests)
                    Toggle("Other Commits", isOn: $release.changelogOptions.includeCommits)
                } label: {
                    Label("Generate", systemImage: "wand.and.stars")
                } primaryAction: {
                    Task { await generate() }
                }
                .fixedSize()
                .disabled(isGenerating)
                .help("Generate notes from completed tasks and the GitHub changes since the compare tag")
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Export…", systemImage: "square.and.arrow.up") {
                    exportedNotes = MarkdownFile(text: release.notesText)
                    isExporting = true
                }
                .labelStyle(.iconOnly)
                .help("Export as Markdown")
                .disabled(release.notesText.isBlank)
            }
            switch mode {
            case .edit:
                TextEditor(text: $release.notesText)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xxs)
                    .frame(minHeight: 220)
                    .background(
                        Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    }
                    .accessibilityLabel("Release notes (Markdown)")
            case .preview:
                Group {
                    if release.notesText.isBlank {
                        Text("No release notes yet.").foregroundStyle(.secondary)
                    } else {
                        MarkdownPreview(markdown: release.notesText)
                    }
                }
                .frame(minHeight: 220, alignment: .topLeading)
            }
            changeSummary
            ForEach(release.notesWarnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = release.changesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
        .onDisappear { Task { await release.flushNotes() } }
        .confirmationDialog(
            "Replace the current notes?", isPresented: isConfirmingReplace, titleVisibility: .visible
        ) {
            Button("Replace Notes", role: .destructive) {
                if let generated { release.notesText = generated }
                generated = nil
            }
        } message: {
            Text("The generated notes replace what you wrote. Export them first to keep a copy.")
        }
        .fileExporter(
            isPresented: $isExporting, document: exportedNotes, contentType: MarkdownFile.markdown,
            defaultFilename: "Release notes \(release.plan?.version ?? "")"
        ) { _ in exportedNotes = nil }
    }

    @ViewBuilder
    private var changeSummary: some View {
        if let changes = release.currentChanges {
            HStack(spacing: Spacing.xs) {
                Text(
                    "\(changes.totalCommits) \(changes.totalCommits == 1 ? "commit" : "commits") and "
                        + "\(changes.pullRequests.count) merged pull requests"
                        + (changes.baseTag.map { " since \($0)" } ?? ""))
                if let url = changes.compareURL { Link("Compare on GitHub", destination: url) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var isConfirmingReplace: Binding<Bool> {
        Binding(get: { generated != nil }, set: { if !$0 { generated = nil } })
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }
        guard let notes = await release.generatedNotes() else { return }
        if release.notesText.isBlank || release.notesText == notes {
            release.notesText = notes
        } else {
            generated = notes
        }
    }
}
