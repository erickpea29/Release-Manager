import RelvoraCore
import SwiftUI

/// A project's release plans: the list, and the selected plan's preparation and GitHub status.
struct ReleasePlansView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WorkspaceModel
    @State private var selection: UUID?
    @State private var planToCancel: ReleasePlan?
    @State private var planToDelete: ReleasePlan?

    var body: some View {
        Group {
            if model.releasePlans.isEmpty {
                ContentUnavailableView {
                    Label("No Release Plans", systemImage: "shippingbox")
                } description: {
                    Text("Plan the next version, then assign tasks to it from the task editor.")
                } actions: {
                    Button("New Release Plan") { model.planEditor = .new }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    planList
                    Divider()
                    if let id = selection, model.plan(id) != nil {
                        ReleasePlanDetailContainer(
                            planID: id, workspace: model, github: app.github, preferences: app.preferences
                        )
                        .id(id)
                    } else {
                        ContentUnavailableView("Select a Release Plan", systemImage: "shippingbox")
                    }
                }
            }
        }
        .onAppear { selection = selection ?? defaultSelection }
        .onChange(of: model.releasePlans.map(\.id)) {
            if model.plan(selection) == nil { selection = defaultSelection }
        }
        .confirmationDialog(
            "Cancel \(planToCancel?.version ?? "")?", isPresented: isPresent($planToCancel), titleVisibility: .visible,
            presenting: planToCancel
        ) { plan in
            Button("Cancel Plan", role: .destructive) { Task { await model.cancelPlan(plan) } }
            Button("Keep Plan", role: .cancel) {}
        } message: { _ in
            Text("The plan is kept as a record and you can start a new one. Its tasks stay assigned.")
        }
        .confirmationDialog(
            "Delete \(planToDelete?.version ?? "")?", isPresented: isPresent($planToDelete), titleVisibility: .visible,
            presenting: planToDelete
        ) { plan in
            Button("Delete Plan", role: .destructive) { Task { await model.deletePlan(plan) } }
        } message: { plan in
            let count = model.taskCount(for: plan)
            Text(count == 0 ? "This can’t be undone." : "Its \(count) tasks stay on the board without a release.")
        }
    }

    /// The active plan, else the newest.
    private var defaultSelection: UUID? { (model.activePlan ?? model.releasePlans.last)?.id }

    private var planList: some View {
        List(selection: $selection) {
            ForEach(model.releasePlans.reversed()) { plan in
                ReleasePlanRow(plan: plan, taskCount: model.taskCount(for: plan), isSelected: plan.id == selection)
                    .tag(plan.id)
                    .contextMenu {
                        Button("Edit…") { model.planEditor = .edit(plan) }
                            .disabled(!ReleasePlanRules.isEditable(plan))
                        Button("Cancel Plan…") { planToCancel = plan }
                            .disabled(!ReleasePlanRules.isEditable(plan))
                        Divider()
                        Button("Delete Plan…", role: .destructive) { planToDelete = plan }
                            .disabled(!ReleasePlanRules.isDeletable(plan))
                    }
            }
        }
        .accessibilityLabel("Release plans")
        .frame(width: 250)
    }

    private func isPresent(_ item: Binding<ReleasePlan?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

struct ReleasePlanRow: View {
    let plan: ReleasePlan
    let taskCount: Int
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.version)
                    .font(.headline.monospaced())
                    .lineLimit(1)
                Spacer()
                RowStatusLabel(plan.status, isSelected: isSelected)
            }
            // Full-strength text when selected: secondary text failed the contrast audit on the gray (inactive)
            // selection highlight.
            if let title = plan.title {
                Text(title)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var parts = ["\(taskCount) \(taskCount == 1 ? "task" : "tasks")"]
        if let released = plan.releasedAt {
            parts.append("Released \(released.formatted(date: .abbreviated, time: .omitted))")
        } else if let date = plan.plannedDate {
            parts.append("Planned for \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Owns one plan's `ReleaseModel` for as long as the plan is selected.
private struct ReleasePlanDetailContainer: View {
    @State private var release: ReleaseModel

    init(planID: UUID, workspace: WorkspaceModel, github: GitHubModel, preferences: Preferences) {
        _release = State(
            initialValue: ReleaseModel(planID: planID, workspace: workspace, github: github, preferences: preferences))
    }

    var body: some View {
        ReleasePlanDetailView(release: release)
    }
}

struct ReleasePlanEditorSheet: View {
    let request: PlanEditorRequest
    let model: WorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReleasePlan
    @State private var hasPlannedDate: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(request: PlanEditorRequest, model: WorkspaceModel) {
        self.request = request
        self.model = model
        let plan: ReleasePlan
        switch request {
        case .new: plan = ReleasePlan(projectID: model.projectID, version: "")
        case .edit(let existing): plan = existing
        }
        _draft = State(initialValue: plan)
        _hasPlannedDate = State(initialValue: plan.plannedDate != nil)
    }

    private var versionHint: (text: String, isError: Bool) {
        guard !draft.version.isBlank else { return ("Semantic version (1.4.0, 2.0.0-beta.1) or a short label", false) }
        switch try? ReleaseVersion(parsing: draft.version) {
        case .semantic(let version)?:
            return (version.isPrerelease ? "Semantic version, prerelease" : "Semantic version", false)
        case .custom?:
            return ("Custom label, sorted after semantic versions", false)
        case nil:
            return ("Not a usable version", true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(request.id == "new" ? "New Release Plan" : "Edit Release Plan")
                .font(.title2.bold())
            Form {
                Section {
                    TextField("Version", text: $draft.version, prompt: Text("1.4.0"))
                        .font(.body.monospaced())
                    Text(versionHint.text)
                        .font(.caption)
                        .foregroundStyle(versionHint.isError ? .red : .secondary)
                    TextField("Title", text: optional(\.title), prompt: Text("Optional"))
                    Toggle("Planned date", isOn: $hasPlannedDate)
                    if hasPlannedDate {
                        DatePicker(
                            "Date",
                            selection: Binding(get: { draft.plannedDate ?? .now }, set: { draft.plannedDate = $0 }),
                            displayedComponents: .date
                        )
                    }
                }
                Section("Notes") {
                    TextEditor(text: optional(\.details))
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.id == "new" ? "Create Plan" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.version.isBlank || isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 460, height: 470)
    }

    private func optional(_ keyPath: WritableKeyPath<ReleasePlan, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var plan = draft
        if !hasPlannedDate { plan.plannedDate = nil } else if plan.plannedDate == nil { plan.plannedDate = .now }
        do {
            try await model.savePlan(request, draft: plan)
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
