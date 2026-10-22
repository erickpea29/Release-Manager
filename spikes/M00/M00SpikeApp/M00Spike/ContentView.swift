import AppKit
import PersistenceSpike
import SwiftUI

@Observable
final class ProjectListModel {
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    private let repository: (any ProjectRepository)?

    init() {
        do {
            repository = try AppStore.makeRepository()
        } catch {
            repository = nil
            errorMessage = "Could not open the local store: \(error.localizedDescription)"
        }
    }

    func load() async {
        await perform { try await $0.allProjects() }
    }

    func add(named name: String) async {
        await perform { repository in
            try await repository.save(ProjectSummary(name: name))
            return try await repository.allProjects()
        }
    }

    func delete(_ id: UUID) async {
        await perform { repository in
            try await repository.delete(id: id)
            return try await repository.allProjects()
        }
    }

    private func perform(_ operation: (any ProjectRepository) async throws -> [ProjectSummary]) async {
        guard let repository else { return }
        do {
            projects = try await operation(repository)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var model = ProjectListModel()
    @State private var selection: UUID?
    @State private var newName = ""
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("windowMaterial") private var windowMaterial: WindowMaterialPreference = .opaque
    @AppStorage("appearance") private var appearance: AppearancePreference = .system

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(model.projects, selection: $selection) { project in
                Label(project.name, systemImage: "shippingbox")
                    .contextMenu {
                        Button("Delete", role: .destructive) { Task { await model.delete(project.id) } }
                    }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("New project", text: $newName)
                        .onSubmit(addProject)
                    Button("Add", systemImage: "plus", action: addProject)
                        .labelStyle(.iconOnly)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
            }
        } detail: {
            ReadabilityPanel(projectCount: model.projects.count, errorMessage: model.errorMessage)
                .toolbar {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Material", selection: $windowMaterial) {
                        ForEach(WindowMaterialPreference.allCases) { Text($0.label).tag($0) }
                    }
                }
        }
        .modifier(WindowMaterialModifier(preference: windowMaterial))
        .task {
            await model.load()
            if WindowInspector.isEnabled { await WindowInspector.reportAndExit() }
        }
    }

    private func addProject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        Task { await model.add(named: name) }
    }
}

/// Representative text and controls over each background treatment, for the contrast check.
struct ReadabilityPanel: View {
    let projectCount: Int
    let errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Readability check").font(.largeTitle.bold())
                Text("\(projectCount) project(s) persisted in the sandboxed SwiftData store.")
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                HStack(alignment: .top, spacing: 16) {
                    SampleCard(title: "Opaque card", background: AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                    SampleCard(title: "Thick material card", background: AnyShapeStyle(.thickMaterial))
                    SampleCard(title: "No card", background: AnyShapeStyle(.clear))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SampleCard: View {
    let title: String
    let background: AnyShapeStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("v1.10.0 · 12 tasks · 3 open").foregroundStyle(.secondary)
            Text("Tertiary metadata").font(.caption).foregroundStyle(.tertiary)
            Button("Prepare Release") {}
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Translucency is never applied when the user enables Reduce Transparency.
struct WindowMaterialModifier: ViewModifier {
    let preference: WindowMaterialPreference
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch reduceTransparency ? .opaque : preference {
        case .opaque:
            content.containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        case .swiftUIMaterial:
            content.containerBackground(.ultraThinMaterial, for: .window)
        case .appKitVisualEffect:
            content.containerBackground(for: .window) { VisualEffectBackground() }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
