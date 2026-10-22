import RelvoraCore
import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case history
    case project(UUID)

    /// Stable string form for scene storage.
    var storageID: String {
        switch self {
        case .dashboard: "dashboard"
        case .history: "history"
        case .project(let id): "project:\(id.uuidString)"
        }
    }

    init?(storageID: String) {
        switch storageID {
        case "dashboard": self = .dashboard
        case "history": self = .history
        default:
            guard storageID.hasPrefix("project:"), let id = UUID(uuidString: String(storageID.dropFirst(8))) else {
                return nil
            }
            self = .project(id)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebarSelection") private var selectionID = SidebarItem.dashboard.storageID
    // Stored explicitly: window restoration alone reopened the sidebar collapsed (M00 F11).
    @AppStorage(PreferenceKey.sidebarVisible) private var sidebarVisible = true
    @AppStorage(PreferenceKey.windowMaterial) private var windowMaterial = WindowMaterial.opaque

    var body: some View {
        @Bindable var model = model
        Group {
            if let startupError = model.startupError {
                StoreUnavailableView(error: startupError)
            } else {
                NavigationSplitView(columnVisibility: columnVisibility) {
                    SidebarView(selection: selection)
                } detail: {
                    detail
                }
            }
        }
        .windowMaterial(windowMaterial)
        .sheet(isPresented: $model.isPresentingNewProject) {
            NewProjectSheet { project in selectionID = SidebarItem.project(project.id).storageID }
        }
        .alert(
            model.operationError?.title ?? "",
            isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } }),
            presenting: model.operationError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private var detail: some View {
        switch SidebarItem(storageID: selectionID) ?? .dashboard {
        case .dashboard:
            DashboardView { selectionID = SidebarItem.project($0).storageID }
        case .history:
            ReleaseHistoryView()
        case .project(let id):
            if let project = model.projects.first(where: { $0.id == id }) {
                ProjectDetailView(project: project)
            } else if model.hasLoaded {
                ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
            } else {
                ProgressView()
            }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(storageID: selectionID) },
            set: { selectionID = ($0 ?? .dashboard).storageID }
        )
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = $0 != .detailOnly }
        )
    }
}

struct StoreUnavailableView: View {
    let error: PersistenceError

    var body: some View {
        ContentUnavailableView {
            Label(error.errorDescription ?? "Relvora couldn’t open its data.", systemImage: "externaldrive.badge.xmark")
        } description: {
            Text(error.recoverySuggestion ?? "")
        } actions: {
            Button("Quit Relvora") { NSApplication.shared.terminate(nil) }
        }
    }
}
