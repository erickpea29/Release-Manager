import RelvoraCore
import SwiftUI

/// Creates a project or edits its name, description, and group.
struct ProjectEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ProjectEditorRequest
    let onCreated: (Project) -> Void

    @State private var name: String
    @State private var details: String
    @State private var groupID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(request: ProjectEditorRequest, onCreated: @escaping (Project) -> Void) {
        self.request = request
        self.onCreated = onCreated
        switch request {
        case .new:
            _name = State(initialValue: "")
            _details = State(initialValue: "")
        case .newInGroup(let groupID):
            _name = State(initialValue: "")
            _details = State(initialValue: "")
            _groupID = State(initialValue: groupID)
        case .edit(let project):
            _name = State(initialValue: project.name)
            _details = State(initialValue: project.details ?? "")
            _groupID = State(initialValue: project.groupID)
        }
    }

    private var isNew: Bool { if case .edit = request { false } else { true } }

    /// The columns new projects start with, from Settings › Board.
    private var columnNames: String {
        model.preferences.newProjectColumns.map(\.name).formatted(.list(type: .and))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(isNew ? "New Project" : "Edit Project")
                .font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Project name"))
                TextField("Description", text: $details, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                if !model.groups.isEmpty {
                    Picker("Group", selection: $groupID) {
                        Text("None").tag(UUID?.none)
                        Divider()
                        ForEach(model.groups) { group in
                            Text(group.name).tag(UUID?.some(group.id))
                        }
                    }
                }
            }
            if isNew {
                Text("New projects start with \(columnNames) columns.")
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
            case .new, .newInGroup:
                onCreated(try await model.createProject(name: name, details: details, groupID: groupID))
            case .edit(let project):
                try await model.updateProject(project, name: name, details: details, groupID: groupID)
            }
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
