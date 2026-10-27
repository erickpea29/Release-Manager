import AppKit
import RelvoraCore
import SwiftUI
import UniformTypeIdentifiers

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
    // Sidebar visibility is a stored preference: window restoration alone reopened the sidebar collapsed (M00 F11).
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var model = model
        @Bindable var updates = model.updates
        Group {
            if let startupError = model.startupError {
                StoreUnavailableView(error: startupError)
            } else {
                SidebarContainer(selection: selection) {
                    detail
                }
            }
        }
        .windowMaterial(preferences.windowMaterial)
        .sheet(item: $model.projectEditor) { request in
            ProjectEditorSheet(request: request) { project in select(.project(project.id)) }
        }
        .sheet(item: $model.groupEditor) { request in
            GroupEditorSheet(request: request)
        }
        .confirmationDialog(
            "Delete the group “\(model.groupPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { model.groupPendingDeletion != nil }, set: { if !$0 { model.groupPendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: model.groupPendingDeletion
        ) { group in
            Button("Delete Group", role: .destructive) { Task { await model.deleteGroup(group) } }
        } message: { group in
            Text(groupDeletionMessage(group))
        }
        .confirmationDialog(
            "Delete “\(model.projectPendingDeletion?.name ?? "")”?",
            isPresented: Binding(
                get: { model.projectPendingDeletion != nil }, set: { if !$0 { model.projectPendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: model.projectPendingDeletion
        ) { project in
            Button("Delete Project", role: .destructive) {
                if selectionID == SidebarItem.project(project.id).storageID { select(.dashboard) }
                Task { await model.deleteProject(project) }
            }
        } message: { _ in
            Text(
                "Its board, tasks, and release plans are deleted too. This can’t be undone. Archive it instead to keep a record."
            )
        }
        .fileExporter(
            isPresented: $model.isExportingBackup,
            document: model.backupToExport,
            contentType: .json,
            defaultFilename: AppModel.backupFileName
        ) { result in
            model.finishBackupExport(result)
        }
        .fileImporter(isPresented: $model.isChoosingBackup, allowedContentTypes: [.json]) { result in
            model.inspectBackup(result)
        }
        .alert(
            "Restore “\(model.pendingRestore?.fileName ?? "")”?",
            isPresented: Binding(get: { model.pendingRestore != nil }, set: { if !$0 { model.pendingRestore = nil } }),
            presenting: model.pendingRestore
        ) { _ in
            Button("Replace All Data", role: .destructive) { Task { await model.confirmRestore() } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                "This backup from \(pending.summary.exportedAt.formatted(date: .abbreviated, time: .shortened)) has "
                    + "\(pending.summary.projectCount) projects and \(pending.summary.taskCount) tasks. It replaces all "
                    + "current data. Relvora saves a copy of your current data first."
            )
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { alert in
            if let url = alert.revealURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
        // Initial too: the menu bar icon, a Spotlight result, or a Shortcut can ask before this window appears.
        .onChange(of: model.navigationRequest, initial: true) { _, request in
            guard let request else { return }
            select(request)
            model.navigationRequest = nil
        }
        .onChange(of: selectionID, initial: true) { _, id in
            if case .project(let projectID)? = SidebarItem(storageID: id) {
                model.currentProjectID = projectID
            } else {
                model.currentProjectID = nil
            }
        }
        .sheet(isPresented: $model.isShowingQuickActions) {
            QuickActionsView()
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateSheet()
        }
        .task {
            guard model.startupError == nil else { return }
            await model.updates.runAutomaticChecks()
        }
        .task {
            guard model.startupError == nil else { return }
            await model.watchDrafts()
        }
        .task {
            guard model.startupError == nil else { return }
            await model.watchPullRequests()
        }
        .task {
            await model.start()
            if let name = model.options.initialProjectName,
                let project = model.projects.first(where: { $0.name == name })
            {
                select(.project(project.id))
            } else if let view = model.options.initialView, let item = SidebarItem(storageID: view) {
                select(item)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch SidebarItem(storageID: selectionID) ?? .dashboard {
        case .dashboard:
            DashboardView { select(.project($0)) }
        case .history:
            ReleaseHistoryView()
        case .project(let id):
            if let project = model.projects.first(where: { $0.id == id }) {
                ProjectWorkspaceView(project: project)
                    .id(project.id)
            } else if model.hasLoaded {
                ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
            } else {
                ProgressView()
            }
        }
    }

    private func groupDeletionMessage(_ group: ProjectGroup) -> String {
        let count = model.projects.count { $0.groupID == group.id }
        return switch count {
        case 0: "The group is empty."
        case 1: "Its project isn’t deleted. It moves out of the group."
        default: "Its \(count) projects aren’t deleted. They move out of the group."
        }
    }

    private func select(_ item: SidebarItem) {
        selectionID = item.storageID
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(storageID: selectionID) },
            set: { selectionID = ($0 ?? .dashboard).storageID }
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
