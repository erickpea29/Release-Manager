import RelvoraCore
import SwiftUI

/// The project's release checklist on a plan that is being prepared: every step must be ticked before the draft.
struct ReleaseChecklistSection: View {
    let release: ReleaseModel
    @State private var isEditing = false

    var body: some View {
        if let plan = release.plan {
            let steps = release.workspace.releaseSteps
            let done = steps.count { plan.completedStepIDs.contains($0.id) }
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(
                        "Release Checklist",
                        detail: steps.isEmpty
                            ? "Your own steps to check before every release of this project, such as “Test on a clean Mac”."
                            : "\(done) of \(steps.count) done. Every step must be ticked before the draft is created.")
                    Spacer()
                    Button(steps.isEmpty ? "Add Steps…" : "Edit Steps…") { isEditing = true }
                }
                ForEach(steps) { step in
                    Toggle(
                        step.title,
                        isOn: Binding(
                            get: { plan.completedStepIDs.contains(step.id) },
                            set: { isDone in Task { await release.setStep(step.id, done: isDone) } }
                        )
                    )
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Release Checklist")
            .sheet(isPresented: $isEditing) {
                ReleaseChecklistEditorSheet(model: release.workspace, onSave: release.checklistDidChange)
            }
        }
    }
}

/// Edits the project's release checklist: add, rename, reorder, delete, or copy steps from another project.
struct ReleaseChecklistEditorSheet: View {
    let model: WorkspaceModel
    let onSave: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [ReleaseStep]
    @State private var otherChecklists: [(project: Project, steps: [ReleaseStep])] = []
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focusedStep: UUID?

    init(model: WorkspaceModel, onSave: @escaping () -> Void = {}) {
        self.model = model
        self.onSave = onSave
        _steps = State(initialValue: model.releaseSteps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Release Checklist").font(.title2.bold())
                Text(
                    "Steps to tick before every release of this project. The draft can’t be created until all are "
                        + "done. Releases already drafted keep their checklist as it was."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach($steps) { $step in
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        TextField("Step", text: $step.title, prompt: Text("Test on a clean Mac"))
                            .textFieldStyle(.plain)
                            .focused($focusedStep, equals: step.id)
                            .accessibilityLabel("Step")
                        Button("Delete Step", systemImage: "minus.circle") {
                            steps.removeAll { $0.id == step.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
                .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .frame(minHeight: 180)
            .overlay {
                if steps.isEmpty {
                    Text("No steps yet").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Add Step", systemImage: "plus", action: addStep)
                if !otherChecklists.isEmpty {
                    Menu("Copy from") {
                        ForEach(otherChecklists, id: \.project.id) { other in
                            Button("\(other.project.name) (\(other.steps.count))") { copy(other.steps) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Text("Drag to reorder.").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 480, height: 440)
        .task { await loadOtherChecklists() }
    }

    private func addStep() {
        let step = ReleaseStep(projectID: model.projectID, title: "", sortOrder: Double(steps.count + 1))
        steps.append(step)
        focusedStep = step.id
    }

    /// Adds the other project's steps that this checklist doesn't have yet.
    private func copy(_ others: [ReleaseStep]) {
        let titles = Set(steps.map { $0.title.lowercased() })
        for other in others where !titles.contains(other.title.lowercased()) {
            steps.append(
                ReleaseStep(projectID: model.projectID, title: other.title, sortOrder: Double(steps.count + 1)))
        }
    }

    private func loadOtherChecklists() async {
        var result: [(Project, [ReleaseStep])] = []
        for project in app.activeProjects where project.id != model.projectID {
            let steps = await model.releaseSteps(ofProject: project.id)
            if !steps.isEmpty { result.append((project, steps)) }
        }
        otherChecklists = result
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveReleaseSteps(steps)
            onSave()
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}

/// The version a release's changes suggest, beside the plan's version, with a button to use it.
struct VersionSuggestionRow: View {
    let plan: ReleasePlan
    let suggestion: VersionSuggestion
    let use: (SemanticVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if plan.version == suggestion.version.description {
                Label(
                    "\(plan.version) matches the changes: \(suggestion.reason).", systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: Spacing.s) {
                    Text(plan.version).font(.body.monospaced())
                    Text("Suggested: \(suggestion.version.description), for \(suggestion.reason).")
                        .foregroundStyle(.secondary)
                    Button("Use \(suggestion.version.description)") { use(suggestion.version) }
                        .buttonStyle(.link)
                }
            }
            if let note = suggestion.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension VersionSuggestion.Bump {
    var title: String {
        switch self {
        case .first: "First"
        case .patch: "Patch"
        case .minor: "Minor"
        case .major: "Major"
        }
    }
}
