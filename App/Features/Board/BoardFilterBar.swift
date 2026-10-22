import RelvoraCore
import SwiftUI

struct BoardFilterBar: View {
    @Bindable var model: WorkspaceModel

    private var visibleCount: Int { model.state.tasks.filter(model.filter.matches).count }

    // Scrolls horizontally instead of imposing a minimum width: a wide filter bar made the split view
    // collapse the sidebar on smaller windows.
    var body: some View {
        ScrollView(.horizontal) {
            controls
        }
        .scrollIndicators(.never)
    }

    private var controls: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter tasks", text: $model.filter.text, prompt: Text("Filter tasks"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
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
            Picker("Release", selection: $model.filter.release) {
                Text("Any release").tag(TaskFilter.Release.any)
                Text("No release").tag(TaskFilter.Release.unassigned)
                ForEach(model.releasePlans.filter { $0.status != .cancelled }) { plan in
                    Text(plan.version).tag(TaskFilter.Release.plan(plan.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Hide completed", isOn: $model.filter.hideCompleted)
                .toggleStyle(.checkbox)
            if model.filter.isActive {
                Button("Clear") { model.filter = TaskFilter() }
                Text("\(visibleCount) of \(model.state.tasks.count) tasks")
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
