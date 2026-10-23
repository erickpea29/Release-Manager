import RelvoraCore
import SwiftUI

/// The version being planned and the Backlog in one list, like a sprint above its backlog. Move a task between them
/// with the arrow on its row, by dragging it to the other section, or from its context menu. Double-click or Return
/// opens a task; Delete asks to delete it.
struct BacklogView: View {
    @Bindable var model: WorkspaceModel
    @State private var selection: UUID?
    @State private var taskToDelete: ProjectTask?
    @SceneStorage("backlogShowsDone") private var showsDone = false

    var body: some View {
        List(selection: $selection) {
            versionSection
            backlogSection
            if !model.doneOutsideVersion.isEmpty { doneSection }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let task = ids.first.flatMap(model.state.task) { menu(for: task) }
        } primaryAction: { ids in
            if let task = ids.first.flatMap(model.state.task) { model.taskEditor = .edit(task) }
        }
        .onDeleteCommand { taskToDelete = selection.flatMap(model.state.task) }
        .confirmationDialog(
            "Delete “\(taskToDelete?.title ?? "")”?",
            isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } }),
            titleVisibility: .visible, presenting: taskToDelete
        ) { task in
            Button("Delete Task", role: .destructive) { Task { await model.deleteTask(task.id) } }
        } message: { _ in
            Text("This can’t be undone.")
        }
        .accessibilityLabel("Backlog")
        .accessibilityIdentifier("backlog")
    }

    // MARK: Sections

    @ViewBuilder
    private var versionSection: some View {
        Section {
            if let plan = model.activePlan {
                ForEach(model.visibleVersionTasks) { task in
                    BacklogRow(task: task, status: model.columnName(task.columnID)) {
                        Button("Move to Backlog", systemImage: "arrow.down.circle") { move(task.id, to: nil) }
                    }
                    .tag(task.id)
                }
                .dropDestination(for: String.self) { items, _ in drop(items, to: plan.id) }
                if model.visibleVersionTasks.isEmpty {
                    DropPlaceholder(
                        text: model.versionTaskCount == 0
                            ? "Nothing in \(plan.version) yet. Use ↑ on a Backlog task, or drag it here."
                            : "No matching tasks"
                    ) { drop($0, to: plan.id) }
                }
                QuickAddRow(prompt: "Add a task to \(plan.version)") {
                    await model.quickAdd(title: $0, inVersion: true)
                }
            } else {
                HStack {
                    Text("No version in progress. Plan the next one to choose what goes into it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("New Release Plan…") { model.planEditor = .new }
                }
                .padding(.vertical, Spacing.xxs)
            }
        } header: {
            if let plan = model.activePlan {
                VersionHeader(plan: plan, done: doneCount(plan), total: model.versionTaskCount)
            } else {
                BacklogSectionTitle(title: "Next Version", detail: nil)
            }
        }
    }

    private var backlogSection: some View {
        Section {
            ForEach(model.visibleBacklogTasks) { task in
                BacklogRow(task: task, status: model.columnName(task.columnID)) {
                    if let plan = model.activePlan {
                        Button("Add to \(plan.version)", systemImage: "arrow.up.circle") { move(task.id, to: plan.id) }
                    }
                }
                .tag(task.id)
            }
            .dropDestination(for: String.self) { items, _ in drop(items, to: nil) }
            if model.visibleBacklogTasks.isEmpty {
                DropPlaceholder(text: model.backlogTasks.isEmpty ? "The Backlog is empty." : "No matching tasks") {
                    drop($0, to: nil)
                }
            }
            QuickAddRow(prompt: "Add a task to the Backlog") { await model.quickAdd(title: $0, inVersion: false) }
        } header: {
            BacklogSectionTitle(title: "Backlog", detail: count(model.backlogTasks.count))
        }
    }

    private var doneSection: some View {
        Section {
            if showsDone {
                ForEach(model.visibleDoneOutsideVersion) { task in
                    BacklogRow(task: task, status: model.columnName(task.columnID)) { EmptyView() }
                        .tag(task.id)
                }
            }
        } header: {
            HStack {
                BacklogSectionTitle(title: "Done Outside a Version", detail: count(model.doneOutsideVersion.count))
                Spacer()
                Button(showsDone ? "Hide" : "Show") { showsDone.toggle() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func menu(for task: ProjectTask) -> some View {
        Button("Open Task") { model.taskEditor = .edit(task) }
        if let plan = model.activePlan {
            if task.releasePlanID == plan.id {
                Button("Move to Backlog") { move(task.id, to: nil) }
            } else {
                Button("Add to \(plan.version)") { move(task.id, to: plan.id) }
            }
        }
        Menu("Status") {
            ForEach(model.columns) { column in
                Button(column.name) { Task { await model.moveTask(task.id, to: column.id, before: nil) } }
                    .disabled(column.id == task.columnID)
            }
        }
        Divider()
        Button("Delete Task…", role: .destructive) { taskToDelete = task }
    }

    private func move(_ taskID: UUID, to planID: UUID?) {
        Task { await model.setVersion(of: taskID, to: planID) }
    }

    private func drop(_ items: [String], to planID: UUID?) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:)).filter { model.state.task($0) != nil }
        guard !ids.isEmpty else { return false }
        Task { for id in ids { await model.setVersion(of: id, to: planID) } }
        return true
    }

    private func doneCount(_ plan: ReleasePlan) -> Int {
        model.state.tasks.filter { $0.releasePlanID == plan.id && $0.completedAt != nil }.count
    }

    private func count(_ value: Int) -> String { value == 1 ? "1 task" : "\(value) tasks" }
}

/// One task: priority, type, title, labels, checklist progress, its column (status), and one move button.
private struct BacklogRow<Action: View>: View {
    let task: ProjectTask
    let status: String?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: Spacing.s) {
            PriorityIndicator(priority: task.priority)
                .frame(width: 14)
            Image(systemName: task.type.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(task.type.title)
                .accessibilityLabel(task.type.title)
            if task.completedAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Done")
            }
            Text(task.title)
                .lineLimit(1)
                .layoutPriority(1)
            ForEach(task.labels.prefix(3), id: \.self) { LabelChip(text: $0) }
            Spacer(minLength: Spacing.s)
            if !task.checklist.isEmpty {
                // Separate elements, primary digits: as one secondary label, it failed the contrast audit.
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("\(task.checklist.filter(\.isDone).count)/\(task.checklist.count)")
                        .monospacedDigit()
                        .accessibilityLabel(
                            "Checklist \(task.checklist.filter(\.isDone).count) of \(task.checklist.count)")
                }
                .font(.caption)
            }
            if let status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Status: \(status)")
            }
            action
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(helpText)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .draggable(task.id.uuidString) {
            Label(task.title, systemImage: task.type.symbol)
                .padding(Spacing.xs)
                .background(.background, in: RoundedRectangle(cornerRadius: Radius.control))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
    }

    private var helpText: String {
        task.releasePlanID == nil ? "Add to the version being planned" : "Move to the Backlog"
    }
}

/// "Version 0.2.0 · Kanban and backups" with progress and the planned date.
private struct VersionHeader: View {
    let plan: ReleasePlan
    let done: Int
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("Version \(plan.version)")
                .font(.headline)
            if let title = plan.title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(
                "\(done) of \(total) done"
                    + (plan.plannedDate.map { " · Planned for \($0.formatted(date: .abbreviated, time: .omitted))" }
                        ?? "")
            )
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.xs)
    }
}

private struct BacklogSectionTitle: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, Spacing.xs)
    }
}

/// Shown in an empty section; tasks can be dropped on it.
private struct DropPlaceholder: View {
    let text: String
    let onDrop: ([String]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                        style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
            .dropDestination(for: String.self) { items, _ in
                onDrop(items)
            } isTargeted: {
                isTargeted = $0
            }
            .selectionDisabled()
    }
}

/// A text field at the end of a section that adds a task with just a title.
private struct QuickAddRow: View {
    let prompt: String
    let add: (String) async -> Bool
    @State private var title = ""

    var body: some View {
        TextField(prompt, text: $title)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(prompt)
            .onSubmit {
                let text = title
                guard !text.isBlank else { return }
                Task { if await add(text) { title = "" } }
            }
            .selectionDisabled()
    }
}
