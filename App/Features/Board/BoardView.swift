import RelvoraCore
import SwiftUI

/// Kanban board of the version being planned (the Backlog tab has everything else). Drag a card onto another card to
/// place it before that card, or onto a column's empty space to place it at the end. Every move is also available from the keyboard (arrows select, Return opens,
/// Task menu moves), the card's context menu, and VoiceOver actions.
struct BoardView: View {
    @Bindable var model: WorkspaceModel
    @State private var isAddingColumn = false
    @State private var newColumnName = ""
    @State private var taskToDelete: ProjectTask?
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    ForEach(model.columns) { column in
                        BoardColumnView(model: model, column: column, isBoardFocused: isFocused) {
                            isFocused = true
                        }
                        .id(column.id)
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
            .onChange(of: model.selectedTask?.columnID) { _, columnID in
                if let columnID { withAnimation { proxy.scrollTo(columnID) } }
            }
        }
        // Always reachable with Tab, like a text field, even when macOS keyboard navigation is off.
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .delete, .deleteForward]) {
            handle($0)
        }
        // Only while the board itself has focus, so ⌘⌫ and ⌥⌘ arrows keep working in its text fields.
        .focusedSceneValue(
            \.boardActions, isFocused ? BoardActions(model: model) { taskToDelete = model.selectedTask } : nil
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Board")
        .accessibilityIdentifier("board")
        .alert("New Column", isPresented: $isAddingColumn) {
            TextField("Name", text: $newColumnName)
            Button("Add") { Task { await model.addColumn(named: newColumnName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(taskToDelete?.title ?? "")”?",
            isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } }),
            titleVisibility: .visible, presenting: taskToDelete
        ) { task in
            Button("Delete Task", role: .destructive) { Task { await model.deleteTask(task.id) } }
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    /// Arrows select, Return or Space opens, Delete asks to delete. Moving cards uses the Task menu (⌥⌘ arrows).
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        switch press.key {
        case .upArrow: model.moveSelection(.up)
        case .downArrow: model.moveSelection(.down)
        case .leftArrow: model.moveSelection(.left)
        case .rightArrow: model.moveSelection(.right)
        case .return, .space:
            guard let task = model.selectedTask else { return .ignored }
            model.taskEditor = .edit(task)
        case .delete, .deleteForward:
            guard let task = model.selectedTask else { return .ignored }
            taskToDelete = task
        default: return .ignored
        }
        return .handled
    }
}

/// The focused board's task commands, for the Task menu.
struct BoardActions {
    let model: WorkspaceModel
    let requestDelete: () -> Void

    var hasSelection: Bool { model.selectedTask != nil }

    func open() {
        if let task = model.selectedTask { model.taskEditor = .edit(task) }
    }

    func canMove(_ direction: WorkspaceModel.Direction) -> Bool { model.canMoveSelectedTask(direction) }

    func move(_ direction: WorkspaceModel.Direction) {
        Task { await model.moveSelectedTask(direction) }
    }
}

extension FocusedValues {
    @Entry var boardActions: BoardActions?
}

private enum DropTarget: Equatable {
    case before(UUID)
    case end
}

struct BoardColumnView: View {
    @Bindable var model: WorkspaceModel
    let column: BoardColumn
    var isBoardFocused = false
    /// Gives the board keyboard focus after a card is clicked.
    var focusBoard: () -> Void = {}

    @State private var dropTarget: DropTarget?
    @State private var quickTitle = ""
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false

    private var visibleTasks: [ProjectTask] { model.visibleTasks(in: column.id) }
    private var totalCount: Int { model.boardTasks(in: column.id).count }
    /// Every task with this status, Backlog included: deleting the column moves them all.
    private var columnTaskCount: Int { model.state.tasks(in: column.id).count }
    private var index: Int { model.columns.firstIndex(of: column) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: Spacing.xs) {
                        ForEach(visibleTasks) { task in
                            card(task)
                                .id(task.id)
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
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(column.name) tasks")
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selectedTaskID) { _, id in
                    if let id, visibleTasks.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id) } }
                }
            }
            TextField("Add a task", text: $quickTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(quickAdd)
        }
        .padding(Spacing.s)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(column.name) column")
        .accessibilityIdentifier("column-\(column.name)")
        .overlay {
            if dropTarget == .end {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
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
            if columnTaskCount == 0 {
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
                columnTaskCount == 0
                    ? "The column is empty."
                    : "Its \(columnTaskCount) \(columnTaskCount == 1 ? "task moves" : "tasks move"), Backlog tasks "
                        + "included, to the column you choose."
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
            // A badge with primary text: small secondary digits on the tinted column failed the contrast audit.
            Text(visibleTasks.count == totalCount ? "\(totalCount)" : "\(visibleTasks.count) of \(totalCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .accessibilityLabel(
                    visibleTasks.count == totalCount
                        ? "\(totalCount) \(totalCount == 1 ? "task" : "tasks")"
                        : "\(visibleTasks.count) of \(totalCount) tasks shown")
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
        let isSelected = model.selectedTaskID == task.id
        // Every card on the Board is in the same version, so cards don't repeat it.
        return TaskCardView(task: task, plan: nil)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.tint.opacity(isBoardFocused ? 1 : 0.45), lineWidth: 2)
                }
            }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open(task) }
            .accessibilityAction(named: "Move to Previous Column") { moveByAccessibility(task, .left) }
            .accessibilityAction(named: "Move to Next Column") { moveByAccessibility(task, .right) }
            .overlay(alignment: .top) {
                if dropTarget == .before(task.id) {
                    Capsule()
                        .fill(.tint)
                        .frame(height: 3)
                        .offset(y: -5)
                }
            }
            .onTapGesture { open(task) }
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
                Button("Move to Backlog") { Task { await model.setVersion(of: task.id, to: nil) } }
                Divider()
                Button("Delete Task", role: .destructive) { Task { await model.deleteTask(task.id) } }
            }
    }

    private func open(_ task: ProjectTask) {
        model.selectedTaskID = task.id
        focusBoard()
        model.taskEditor = .edit(task)
    }

    private func moveByAccessibility(_ task: ProjectTask, _ direction: WorkspaceModel.Direction) {
        model.selectedTaskID = task.id
        Task { await model.moveSelectedTask(direction) }
    }

    @ViewBuilder
    private var endDropIndicator: some View {
        if dropTarget == .end && !visibleTasks.isEmpty {
            Capsule()
                .fill(.tint)
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
            if await model.quickAdd(title: title, to: column.id, inVersion: true) { quickTitle = "" }
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
