import RelvoraCore
import SwiftUI

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Project) -> Void

    @State private var name = ""
    @State private var details = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New Project")
                .font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("Project name"))
                TextField("Description", text: $details, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...4)
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
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(Spacing.l)
        .frame(width: 420)
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let project = try await model.createProject(name: name, details: details)
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = OperationError(title: "", error: error).message
        }
    }
}
