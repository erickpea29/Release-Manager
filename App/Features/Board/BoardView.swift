import RelvoraCore
import SwiftUI

/// Kanban board. Drag a card onto another card to place it before that card, or onto a column's empty
/// space to place it at the end. Every move is also available from the card's context menu.
struct BoardView: View {
    @Bindable var model: WorkspaceModel
    @State private var isAddingColumn = false
    @State private var newColumnName = ""

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(model.columns) { column in
                    BoardColumnView(model: model, column: column)
                }
                Button("Add Column", systemImage: "plus") {
                    newColumnName = ""
                    isAddingColumn = true
                }
                .buttonStyle(.borderless)
                .padding(.top, Spacing.s)
            }
            .padding(Spacing.l)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .alert("New Column", isPresented: $isAddingColumn) {
            TextField("Name", text: $newColumnName)
            Button("Add") { Task { await model.addColumn(named: newColumnName) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private enum DropTarget: Equatable {
    case before(UUID)
    case end
}

struct BoardColumnView: View {
    @Bindable var model: WorkspaceModel
    let column: BoardColumn

    @State private var dropTarget: DropTarget?
    @State private var quickTitle = ""
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false

    private var visibleTasks: [ProjectTask] { model.visibleTasks(in: column.id) }
    private var totalCount: Int { model.state.tasks(in: column.id).count }
    private var index: Int { model.columns.firstIndex(of: column) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: Spacing.xs) {
                    ForEach(visibleTasks) { task in
                        card(task)
                    }
                    if visibleTasks.isEmpty {
                        Text(totalCount == 0 ? "No tasks" : "No matching tasks")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.m)
                    }
                    endDropIndicator
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
            TextField("Add a task", text: $quickTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(quickAdd)
        }
        .padding(Spacing.s)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay {
            if dropTarget == .end {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, before: nil)
        } isTargeted: { targeted in
            if targeted { dropTarget = .end } else if dropTarget == .end { dropTarget = nil }
        }
        .alert("Rename Column", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { Task { await model.renameColumn(column.id, to: draftName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(column.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            if totalCount == 0 {
                Button("Delete Column", role: .destructive) {
                    Task { await model.deleteColumn(column.id, movingTasksTo: nil) }
                }
            } else {
                ForEach(model.columns.filter { $0.id != column.id }) { destination in
                    Button("Move Tasks to \(destination.name) and Delete", role: .destructive) {
                        Task { await model.deleteColumn(column.id, movingTasksTo: destination.id) }
                    }
                }
            }
        } message: {
            Text(
                totalCount == 0
                    ? "The column is empty."
                    : "Its \(totalCount) \(totalCount == 1 ? "task moves" : "tasks move") to the column you choose."
            )
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Text(column.name)
                .font(.headline)
                .lineLimit(1)
            if column.isCompletionColumn {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Completion column: tasks here count as done")
                    .accessibilityLabel("Completion column")
            }
            Text(visibleTasks.count == totalCount ? "\(totalCount)" : "\(visibleTasks.count) of \(totalCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Rename…") {
                    draftName = column.name
                    isRenaming = true
                }
                Button("Move Left") { Task { await model.moveColumn(column.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move Right") { Task { await model.moveColumn(column.id, by: 1) } }
                    .disabled(index == model.columns.count - 1)
                Button("Make Completion Column") { Task { await model.makeCompletionColumn(column.id) } }
                    .disabled(column.isCompletionColumn)
                Divider()
                Button("Delete Column…", role: .destructive) { isConfirmingDelete = true }
                    .disabled(column.isCompletionColumn || model.columns.count == 1)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(column.name)")
        }
        .padding(.horizontal, Spacing.xxs)
    }

    private func card(_ task: ProjectTask) -> some View {
        TaskCardView(task: task, plan: model.plan(task.releasePlanID))
            .overlay(alignment: .top) {
                if dropTarget == .before(task.id) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .offset(y: -5)
                }
            }
            .onTapGesture { model.taskEditor = .edit(task) }
            .draggable(task.id.uuidString) {
                TaskCardView(task: task, plan: nil)
                    .frame(width: 260)
            }
            .dropDestination(for: String.self) { items, _ in
                drop(items, before: task.id)
            } isTargeted: { targeted in
                if targeted {
                    dropTarget = .before(task.id)
                } else if dropTarget == .before(task.id) {
                    dropTarget = nil
                }
            }
            .contextMenu {
                Button("Edit…") { model.taskEditor = .edit(task) }
                Menu("Move To") {
                    ForEach(model.columns.filter { $0.id != column.id }) { destination in
                        Button(destination.name) {
                            Task { await model.moveTask(task.id, to: destination.id, before: nil) }
                        }
                    }
                }
                Divider()
                Button("Delete Task", role: .destructive) { Task { await model.deleteTask(task.id) } }
            }
    }

    @ViewBuilder
    private var endDropIndicator: some View {
        if dropTarget == .end && !visibleTasks.isEmpty {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 3)
        }
    }

    private func drop(_ items: [String], before taskID: UUID?) -> Bool {
        dropTarget = nil
        guard let text = items.first, let id = UUID(uuidString: text), model.state.task(id) != nil else {
            return false
        }
        Task { await model.moveTask(id, to: column.id, before: taskID) }
        return true
    }

    private func quickAdd() {
        let title = quickTitle
        guard !title.isBlank else { return }
        Task {
            if await model.quickAdd(title: title, to: column.id) { quickTitle = "" }
        }
    }
}

struct TaskCardView: View {
    let task: ProjectTask
    let plan: ReleasePlan?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                if task.completedAt != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PriorityIndicator(priority: task.priority)
            }
            if !task.labels.isEmpty {
                HStack(spacing: Spacing.xxs) {
                    ForEach(task.labels.prefix(3), id: \.self) { LabelChip(text: $0) }
                    if task.labels.count > 3 {
                        Text("+\(task.labels.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Image(systemName: task.type.symbol)
                    .help(task.type.title)
                if !task.checklist.isEmpty {
                    Label(
                        "\(task.checklist.filter(\.isDone).count)/\(task.checklist.count)",
                        systemImage: "checklist"
                    )
                }
                if let plan {
                    Label(plan.version, systemImage: "shippingbox")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: Spacing.s)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the task. Use the context menu to move it.")
    }

    private var accessibilityText: String {
        var parts = [task.title, "\(task.priority.title) priority", task.type.title]
        if task.completedAt != nil { parts.append("Done") }
        if !task.labels.isEmpty { parts.append("Labels: \(task.labels.joined(separator: ", "))") }
        if !task.checklist.isEmpty {
            parts.append("Checklist \(task.checklist.filter(\.isDone).count) of \(task.checklist.count)")
        }
        if let plan { parts.append("Release \(plan.version)") }
        return parts.joined(separator: ", ")
    }
}
