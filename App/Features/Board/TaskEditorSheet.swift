import RelvoraCore
import SwiftUI

struct TaskEditorSheet: View {
    let request: TaskEditorRequest
    let model: WorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProjectTask
    @State private var labelsText: String
    @State private var newItemTitle = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isConfirmingDelete = false

    init(request: TaskEditorRequest, model: WorkspaceModel) {
        self.request = request
        self.model = model
        _draft = State(initialValue: request.task)
        _labelsText = State(initialValue: request.task.labels.joined(separator: ", "))
    }

    /// Active plans can be chosen; the current assignment stays visible even if that plan is finished.
    private var assignablePlans: [ReleasePlan] {
        model.releasePlans.filter { $0.status.isActive || $0.id == draft.releasePlanID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(request.isNew ? "New Task" : "Edit Task")
                .font(.title2.bold())
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("What needs to be done?"))
                    Picker("Column", selection: $draft.columnID) {
                        ForEach(model.columns) { Text($0.name).tag($0.id) }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                            Label(priority.title, systemImage: priority.symbol).tag(priority)
                        }
                    }
                    Picker("Type", selection: $draft.type) {
                        ForEach(TaskType.allCases, id: \.self) { type in
                            Label(type.title, systemImage: type.symbol).tag(type)
                        }
                    }
                    Picker("Release", selection: $draft.releasePlanID) {
                        Text("None").tag(UUID?.none)
                        ForEach(assignablePlans) { plan in
                            Text(plan.version).tag(UUID?.some(plan.id))
                        }
                    }
                    TextField("Labels", text: $labelsText, prompt: Text("Separate with commas"))
                }
                Section("Notes") {
                    TextEditor(text: Binding(get: { draft.details ?? "" }, set: { draft.details = $0 }))
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Notes (Markdown)")
                }
                Section("Checklist") {
                    ForEach($draft.checklist) { $item in
                        HStack {
                            Toggle("Done", isOn: $item.isDone)
                                .labelsHidden()
                            TextField("Item", text: $item.title)
                                .labelsHidden()
                            Button("Remove", systemImage: "minus.circle") {
                                draft.checklist.removeAll { $0.id == item.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("New item", text: $newItemTitle, prompt: Text("Add a checklist item"))
                            .labelsHidden()
                            .onSubmit(addChecklistItem)
                        Button("Add", action: addChecklistItem)
                            .disabled(newItemTitle.isBlank)
                    }
                }
                if !request.isNew {
                    Section {
                        LabeledContent(
                            "Created", value: draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent(
                            "Updated", value: draft.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        if let completed = draft.completedAt {
                            LabeledContent(
                                "Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if !request.isNew {
                    Button("Delete Task", role: .destructive) { isConfirmingDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Add Task" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.isBlank || isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 520, height: 660)
        .confirmationDialog("Delete “\(draft.title)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) {
                Task {
                    await model.deleteTask(draft.id)
                    dismiss()
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func addChecklistItem() {
        guard !newItemTitle.isBlank else { return }
        draft.checklist.append(ChecklistItem(title: newItemTitle, sortOrder: Double(draft.checklist.count + 1)))
        newItemTitle = ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var edited = draft
        edited.labels = labelsText.split(separator: ",").map(String.init)
        if !newItemTitle.isBlank {
            edited.checklist.append(ChecklistItem(title: newItemTitle, sortOrder: Double(edited.checklist.count + 1)))
        }
        do {
            try await model.save(request, edited: edited)
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
