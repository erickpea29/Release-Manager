import RelvoraCore
import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case backlog
    case board
    case releases
    case github

    var id: Self { self }

    var title: String {
        switch self {
        case .backlog: "Backlog"
        case .board: "Board"
        case .releases: "Releases"
        case .github: "GitHub"
        }
    }
}

extension FocusedValues {
    /// Present while a project's Board or Backlog is shown; drives File › New Task (⌘N).
    @Entry var newTaskAction: (@MainActor () -> Void)?
    /// The open project's tab, for Go › Backlog / Board / Releases / GitHub.
    @Entry var workspaceTab: Binding<String>?
}

/// A project's Backlog, Board, release plans, and repositories.
struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var app
    let project: Project

    @State private var model: WorkspaceModel?
    @SceneStorage("workspaceTab") private var tabID = WorkspaceTab.board.rawValue

    private var tab: WorkspaceTab { WorkspaceTab(rawValue: tabID) ?? .board }

    var body: some View {
        Group {
            if let model {
                WorkspaceContent(model: model, project: project, tab: tab) { tabID = $0.rawValue }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(project.isArchived ? "Archived" : (project.details ?? ""))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tabID) {
                    ForEach(WorkspaceTab.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem {
                switch tab {
                case .backlog:
                    Button("New Task", systemImage: "plus") { model?.beginNewTask(inVersion: false) }
                        .help("New Task in the Backlog (\(KeyCommand.newTask.glyphs))")
                case .board:
                    Button("New Task", systemImage: "plus") { model?.beginNewTask() }
                        .help("New Task (\(KeyCommand.newTask.glyphs))")
                case .releases:
                    Button("New Release Plan", systemImage: "plus") { model?.planEditor = .new }
                        .disabled(model?.activePlan != nil)
                        .help(
                            model?.activePlan.map { "Finish or cancel \($0.version) first" } ?? "New Release Plan")
                case .github:
                    EmptyView()
                }
            }
            ToolbarItem {
                Menu {
                    Button("Edit Project…") { app.projectEditor = .edit(project) }
                    Button(project.isArchived ? "Unarchive Project" : "Archive Project") {
                        Task { await app.setArchived(project, !project.isArchived) }
                    }
                    Divider()
                    Button("Delete Project…", role: .destructive) { app.projectPendingDeletion = project }
                } label: {
                    Label("Project Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: "\(project.id)-\(app.dataVersion)") { await makeModel() }
        .onChange(of: app.workspaceRequest) { handleRequest() }
        .onChange(of: app.externalChange) { _, change in
            guard change?.projectID == project.id, let model else { return }
            Task { await model.load() }
        }
        .focusedSceneValue(\.workspaceTab, $tabID)
    }

    /// Applies a request from quick actions or menus once this project's model exists.
    private func handleRequest() {
        guard let request = app.workspaceRequest, request.projectID == project.id, let model else { return }
        app.workspaceRequest = nil
        if let tab = request.tab { tabID = tab.rawValue }
        switch request.action {
        case .newTask?:
            // Into the version on the Board, or the Backlog when no version is planned.
            let onBoard = model.activePlan != nil
            tabID = (onBoard ? WorkspaceTab.board : .backlog).rawValue
            model.beginNewTask(inVersion: onBoard)
        case .newReleasePlan?:
            tabID = WorkspaceTab.releases.rawValue
            if model.activePlan == nil { model.planEditor = .new }
        case nil:
            break
        }
    }

    private func makeModel() async {
        guard let environment = app.environment else { return }
        let projectID = project.id
        let model = WorkspaceModel(projectID: projectID, environment: environment) { [app] in
            await app.refreshStats(for: projectID)
        }
        if let initialTab = app.options.initialTab, WorkspaceTab(rawValue: initialTab) != nil {
            tabID = initialTab
        }
        self.model = model
        await model.load()
        handleRequest()
        #if DEBUG
            if let fullName = app.options.connectRepository, app.github.isConnected,
                !model.connections.contains(where: { $0.fullName == fullName }),
                let remote = try? await app.github.installationRepositories().first(where: { $0.fullName == fullName })
            {
                _ = try? await model.connect(remote)
            }
            if app.options.openNewReleasePlan, app.options.initialProjectName == project.name {
                model.planEditor = .new
            }
        #endif
    }
}

private struct WorkspaceContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: WorkspaceModel
    let project: Project
    let tab: WorkspaceTab
    let showTab: (WorkspaceTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if project.isArchived { archivedBanner }
            mainContent
        }
        .sheet(item: $model.taskEditor) { TaskEditorSheet(request: $0, model: model) }
        .sheet(item: $model.planEditor) { ReleasePlanEditorSheet(request: $0, model: model) }
        .alert(model.alert?.title ?? "", isPresented: isShowingAlert, presenting: model.alert) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        .focusedSceneValue(\.newTaskAction, newTaskAction)
    }

    private var archivedBanner: some View {
        HStack {
            Label("This project is archived.", systemImage: "archivebox")
            Spacer()
            Button("Unarchive") { Task { await app.setArchived(project, false) } }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(.yellow.opacity(0.15))
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorBanner(message: message) { Task { await model.load() } }
            Spacer()
        case .loaded:
            switch tab {
            case .backlog:
                filterBar
                BacklogView(model: model)
            case .board:
                if model.activePlan == nil {
                    NoVersionView(model: model) { showTab(.backlog) }
                } else {
                    filterBar
                    BoardView(model: model)
                }
            case .releases:
                ReleasePlansView(model: model)
            case .github:
                RepositoriesView(model: model)
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        BoardFilterBar(model: model, tab: tab)
        // The line under the filter bar: the sidebar's frame draws it, turning into the sidebar's border.
        Color.clear
            .frame(height: 1)
            .contentTopBorder()
    }

    private var isShowingAlert: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    private var newTaskAction: (@MainActor () -> Void)? {
        let model = model
        switch tab {
        case .board: return { model.beginNewTask() }
        case .backlog: return { model.beginNewTask(inVersion: false) }
        case .releases, .github: return nil
        }
    }
}

/// The Board when no version is planned: it shows a version's tasks, so it offers to plan one.
private struct NoVersionView: View {
    let model: WorkspaceModel
    let showBacklog: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Version in Progress", systemImage: "shippingbox")
        } description: {
            Text(
                "The Board shows the version you’re working on. Plan the next version, then add tasks to it from the Backlog."
            )
        } actions: {
            Button("New Release Plan…") { model.planEditor = .new }
                .buttonStyle(.borderedProminent)
            Button("Open Backlog", action: showBacklog)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
