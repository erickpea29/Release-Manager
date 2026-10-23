import RelvoraCore
import SwiftUI

/// Creates a group, optionally moving a project into it, or renames one.
struct GroupEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: GroupEditorRequest

    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(request: GroupEditorRequest) {
        self.request = request
        switch request {
        case .new: _name = State(initialValue: "")
        case .rename(let group): _name = State(initialValue: group.name)
        }
    }

    private var isNew: Bool { if case .new = request { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(isNew ? "New Group" : "Rename Group")
                .font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Company, client, or product"))
            }
            if case .new(let project?) = request {
                Text("“\(project.name)” moves into the new group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isNew {
                Text("Groups organize the sidebar. Each project keeps its own board, versions, and repositories.")
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
                Button(isNew ? "Create" : "Rename") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isBlank || isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 400)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            switch request {
            case .new(let project): try await model.createGroup(name: name, moving: project)
            case .rename(let group): try await model.renameGroup(group, to: name)
            }
            dismiss()
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }
}
