import RelvoraCore
import SwiftUI

/// Project overview with its board columns. The interactive Kanban board arrives in M02.
struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var columns: [BoardColumn] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(project.name)
                        .font(.largeTitle.bold())
                    if let details = project.details {
                        Text(details)
                            .foregroundStyle(.secondary)
                    }
                    Text("Created \(project.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text("Board")
                    .font(.title2.bold())
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        ForEach(columns) { column in
                            BoardColumnCard(column: column)
                        }
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(project.name)
        .task(id: project.id) { await loadColumns() }
    }

    private func loadColumns() async {
        do {
            columns = try await model.columns(for: project.id)
            loadError = nil
        } catch {
            loadError = OperationError(title: "", error: error).message
        }
    }
}

struct BoardColumnCard: View {
    let column: BoardColumn

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(column.name)
                    .font(.headline)
                Spacer()
                if column.isCompletionColumn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Completion column")
                }
            }
            Text("No tasks")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(width: 200, alignment: .leading)
        .frame(minHeight: 160, alignment: .top)
        .panel()
    }
}
