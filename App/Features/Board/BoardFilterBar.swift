import RelvoraCore
import SwiftUI

/// Filters for the Board and the Backlog tab, which share them. Which version a task is in is the tab's job.
struct BoardFilterBar: View {
    @Bindable var model: WorkspaceModel
    let tab: WorkspaceTab

    private var counts: (visible: Int, total: Int) {
        switch tab {
        case .backlog:
            (
                model.visibleVersionTasks.count + model.visibleBacklogTasks.count
                    + model.visibleDoneOutsideVersion.count,
                model.versionTaskCount + model.backlogTasks.count + model.doneOutsideVersion.count
            )
        default: (model.visibleVersionTasks.count, model.versionTaskCount)
        }
    }

    // Scrolls horizontally instead of imposing a minimum width: a wide filter bar made the split view
    // collapse the sidebar on smaller windows.
    var body: some View {
        ScrollView(.horizontal) {
            controls
        }
        .scrollIndicators(.never)
        .background(Color.chrome)
    }

    private var controls: some View {
        HStack(spacing: Spacing.s) {
            if tab == .board, let plan = model.activePlan {
                VersionBadge(
                    plan: plan,
                    done: model.state.tasks.filter { $0.releasePlanID == plan.id && $0.completedAt != nil }.count,
                    total: model.versionTaskCount)
                Divider()
                    .frame(height: 16)
            }
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter tasks", text: $model.filter.text, prompt: Text("Filter tasks"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel("Filter tasks")
            }
            Menu(title("Priority", count: model.filter.priorities.count)) {
                ForEach(TaskPriority.allCases.reversed(), id: \.self) { priority in
                    Toggle(priority.title, isOn: membership(\.priorities, priority))
                }
            }
            .fixedSize()
            Menu(title("Type", count: model.filter.types.count)) {
                ForEach(TaskType.allCases, id: \.self) { type in
                    Toggle(type.title, isOn: membership(\.types, type))
                }
            }
            .fixedSize()
            Menu(title("Labels", count: model.filter.labels.count)) {
                ForEach(model.allLabels, id: \.self) { label in
                    Toggle(label, isOn: membership(\.labels, label))
                }
            }
            .fixedSize()
            .disabled(model.allLabels.isEmpty)
            Toggle("Hide completed", isOn: $model.filter.hideCompleted)
                .toggleStyle(.checkbox)
            if model.filter.isActive {
                Button("Clear") { model.filter = TaskFilter() }
                Text("\(counts.visible) of \(counts.total) tasks")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func title(_ name: String, count: Int) -> String {
        count == 0 ? name : "\(name) (\(count))"
    }

    private func membership<Value: Hashable>(_ keyPath: WritableKeyPath<TaskFilter, Set<Value>>, _ value: Value)
        -> Binding<Bool>
    {
        Binding(
            get: { model.filter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    model.filter[keyPath: keyPath].insert(value)
                } else {
                    model.filter[keyPath: keyPath].remove(value)
                }
            }
        )
    }
}

/// The version on the Board, with its progress: "0.2.0 · Kanban and backups · 1 of 5 done".
struct VersionBadge: View {
    let plan: ReleasePlan
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(plan.version)
                .font(.callout.weight(.semibold).monospaced())
            if let title = plan.title {
                Text(title)
                    .lineLimit(1)
            }
            Text("· \(done) of \(total) done")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Version \(plan.version)\(plan.title.map { ", \($0)" } ?? ""), \(done) of \(total) done")
    }
}
