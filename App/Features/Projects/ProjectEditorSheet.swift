import RelvoraCore
import SwiftUI

/// Creates a project or edits its name and description.
struct ProjectEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ProjectEditorRequest
    let onCreated: (Project) -> Void

    @State private var name: String
    @State private var details: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(request: ProjectEditorRequest, onCreated: @escaping (Project) -> Void) {
        self.request = request
        self.onCreated = onCreated
        switch request {
        case .new:
            _name = State(initialValue: "")
            _details = State(initialValue: "")
        case .edit(let project):
            _name = State(initialValue: project.name)
            _details = State(initialValue: project.details ?? "")
        }
    }

    private var isNew: Bool { if case .new = request { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(isNew ? "New Project" : "Edit Project")
                .font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Project name"))
                TextField("Description", text: $details, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
            if isNew {
                Text("New projects start with Backlog, To Do, In Progress, Review, and Done columns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button(isNew ? "Create" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isBlank || isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 440)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            switch request {
            case .new:
                onCreated(try await model.createProject(name: name, details: details))
            case .edit(let project):
                try await model.updateProject(project, name: name, details: details)
            }
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
