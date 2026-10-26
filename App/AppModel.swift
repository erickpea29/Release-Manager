import AppKit
import Foundation
import Observation
import RelvoraCore
import RelvoraMCP
import RelvoraPersistence
import RelvoraUpdates

/// Everything the UI depends on, built once at launch. Previews and checks build it from an in-memory store.
struct AppEnvironment: Sendable {
    let store: PersistentStore
    let github: GitHubServices?

    var projects: ProjectService { ProjectService(repository: store.projects) }
    var groups: ProjectGroupService { ProjectGroupService(repository: store.groups) }
    var board: BoardService { BoardService(repository: store.board) }
    var releasePlans: ReleasePlanService { ReleasePlanService(repository: store.releasePlans) }
    var checklist: ReleaseChecklistService {
        ReleaseChecklistService(steps: store.releaseSteps, plans: store.releasePlans)
    }
    var backups: BackupService { BackupService(repository: store.backups) }
    var repositoryConnections: RepositoryConnectionService {
        RepositoryConnectionService(repository: store.repositoryConnections)
    }

    /// `nil` when this build has no GitHub App configured.
    var releaseWorkflow: ReleaseWorkflow? {
        github.map {
            ReleaseWorkflow(
                plans: store.releasePlans, snapshots: store.releaseSnapshots, board: store.board,
                connections: store.repositoryConnections, steps: store.releaseSteps, remote: $0.releases)
        }
    }
}

/// Launch arguments, honored in Debug builds only, e.g. `-RelvoraInMemoryStore YES`.
struct LaunchOptions {
    var inMemoryStore = false
    var storeName = "Relvora"
    var seedSampleData = false
    /// Selects this project (by name) at launch; used for UI checks.
    var initialProjectName: String?
    /// Selects `dashboard` or `history` at launch, unless a project is selected.
    var initialView: String?
    var initialTab: String?
    /// Opens the New Release Plan sheet in the initial project (UI checks of the version suggestion).
    var openNewReleasePlan = false
    /// Starts the GitHub device flow at launch (UI checks of the sign-in).
    var startGitHubConnect = false
    /// Connects this repository (`owner/name`) to the initial project once signed in.
    var connectRepository: String?
    /// Uses the in-memory `DemoGitHub` instead of github.com (UI checks of the release workflow).
    var demoGitHub = false
    /// Runs a `DemoScenario` on the first release plan shown.
    var demoScenario: String?
    /// Keeps settings in this `UserDefaults` suite, emptied at launch (UI tests never touch the real settings).
    var defaultsSuite: String?
    /// `check` runs Check for Updates at launch; `install` also installs what it finds (checks of the updater with
    /// `-RelvoraDemoUpdateVersion`). Not repeated by the copy the update opens.
    var updateAtLaunch: String?
    /// Turns on Claude's connection on this port with this key, instead of the Keychain's (UI tests).
    var claudePort: Int?
    var claudeKey: String?

    static func current(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            // A copy opened by an update gets the launch options of the copy that installed it.
            let ticket = RelaunchTicket.pending(in: defaults)
            func string(_ key: String) -> String? { defaults.string(forKey: key) ?? ticket?.option(key) }
            func bool(_ key: String) -> Bool {
                if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
                return ticket?.option(key).map { ["YES", "1", "true"].contains($0) } ?? false
            }
            options.inMemoryStore = bool("RelvoraInMemoryStore")
            options.storeName = string("RelvoraStoreName") ?? options.storeName
            options.seedSampleData = bool("RelvoraSeedSampleData")
            options.initialProjectName = string("RelvoraInitialProject")
            options.initialView = string("RelvoraInitialView")
            options.initialTab = string("RelvoraInitialTab")
            options.openNewReleasePlan = bool("RelvoraNewReleasePlan")
            options.startGitHubConnect = bool("RelvoraStartGitHubConnect")
            options.connectRepository = string("RelvoraConnectRepository")
            options.demoGitHub = bool("RelvoraDemoGitHub")
            options.demoScenario = string("RelvoraDemoScenario")
            options.defaultsSuite = string("RelvoraDefaultsSuite")
            if ticket == nil { options.updateAtLaunch = defaults.string(forKey: "RelvoraUpdateAtLaunch") }
            options.claudePort = string("RelvoraClaudePort").flatMap(Int.init)
            options.claudeKey = string("RelvoraClaudeKey").flatMap { AccessKey.isWellFormed($0) ? $0 : nil }
        #endif
        return options
    }
}

/// A message for the user: a failed action or a completed one worth confirming.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var revealURL: URL?

    init(title: String, message: String, revealURL: URL? = nil) {
        self.title = title
        self.message = message
        self.revealURL = revealURL
    }

    init(title: String, error: any Error) {
        self.init(title: title, message: Self.message(for: error))
    }

    static func message(for error: any Error) -> String {
        [error.localizedDescription, (error as? any LocalizedError)?.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
    }
}

/// Dashboard numbers for one project.
struct ProjectStats: Equatable {
    var taskCount = 0
    var completedCount = 0
    var activePlanVersion: String?
    /// The plan in progress, if any.
    var activePlan: ReleasePlan?
    /// The newest verified publication.
    var lastRelease: ReleaseSnapshot?

    var progress: Double? { taskCount == 0 ? nil : Double(completedCount) / Double(taskCount) }
}

enum ProjectEditorRequest: Identifiable {
    case new
    /// A new project, already in this group.
    case newInGroup(UUID)
    case edit(Project)

    var id: String {
        switch self {
        case .new: "new"
        case .newInGroup(let groupID): "new-\(groupID.uuidString)"
        case .edit(let project): project.id.uuidString
        }
    }
}

enum GroupEditorRequest: Identifiable {
    /// A new group; `moving`, if set, is put in it once it exists.
    case new(moving: Project?)
    case rename(ProjectGroup)

    var id: String {
        switch self {
        case .new(let project): "new-\(project?.id.uuidString ?? "")"
        case .rename(let group): group.id.uuidString
        }
    }
}

/// Tasks changed outside the project's views (Claude created some): open views reload.
struct ExternalChange: Equatable {
    let projectID: UUID
    let id = UUID()
}

/// Something to do in a project's workspace, requested from outside it (quick actions, menus).
struct WorkspaceRequest: Equatable {
    enum Action: Equatable {
        case newTask
        case newReleasePlan
    }

    let projectID: UUID
    var tab: WorkspaceTab?
    var action: Action?
}

struct PendingRestore: Identifiable {
    let id = UUID()
    let fileName: String
    let document: BackupDocument
    let summary: BackupSummary
}

/// App-wide state shared by all views. Feature rules live in RelvoraCore; this type coordinates.
@Observable
final class AppModel {
    /// All projects, archived included, in creation order.
    private(set) var projects: [Project] = []
    /// Project groups, in sidebar order.
    private(set) var groups: [ProjectGroup] = []
    private(set) var stats: [UUID: ProjectStats] = [:]
    private(set) var hasLoaded = false
    /// Incremented after a restore so open views reload their data.
    private(set) var dataVersion = 0
    /// Set when the local store cannot be opened; the UI shows a recovery screen instead of content.
    let startupError: PersistenceError?

    var alert: AppAlert?
    var projectEditor: ProjectEditorRequest?
    var projectPendingDeletion: Project?
    var groupEditor: GroupEditorRequest?
    var groupPendingDeletion: ProjectGroup?
    var backupToExport: BackupFile?
    var isExportingBackup = false
    var isChoosingBackup = false
    var pendingRestore: PendingRestore?
    /// Every project's release snapshots, for Release History.
    private(set) var releaseHistory: [ReleaseSnapshot] = []
    /// The snapshot Release History shows.
    var historySelection: UUID?
    /// A sidebar destination requested from inside a view (for example "Show in Release History").
    var navigationRequest: SidebarItem?
    /// The project shown in the main window, if any (kept by the root view).
    var currentProjectID: UUID?
    var workspaceRequest: WorkspaceRequest?
    var isShowingQuickActions = false
    /// The last change made outside the views, such as tasks Claude created.
    private(set) var externalChange: ExternalChange?

    let environment: AppEnvironment?
    let options: LaunchOptions
    let github: GitHubModel
    let preferences: Preferences
    let updates: UpdateModel
    let claude: ClaudeConnection
    /// Set when an update opened this copy.
    private let relaunchTicket: RelaunchTicket?

    var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    var archivedProjects: [Project] { projects.filter(\.isArchived) }
    /// Active projects by group, in sidebar order, then those outside any group.
    var projectSections: [ProjectSection] { ProjectGrouping.sections(activeProjects, groups: groups) }

    func group(of project: Project) -> ProjectGroup? {
        project.groupID.flatMap { id in groups.first { $0.id == id } }
    }

    init(options: LaunchOptions = .current()) {
        // Opened by an update: the previous copy closes the data first.
        relaunchTicket = RelaunchTicket.pending()
        if let relaunchTicket {
            UpdateModel.waitForPreviousCopy(relaunchTicket)
            RelaunchTicket.clear()
        }
        self.options = options
        var defaults = UserDefaults.standard
        #if DEBUG
            if let suite = options.defaultsSuite, let isolated = UserDefaults(suiteName: suite) {
                isolated.removePersistentDomain(forName: suite)
                defaults = isolated
            }
        #endif
        preferences = Preferences(defaults: defaults)
        #if DEBUG
            if let port = options.claudePort, options.claudeKey != nil {
                preferences.claudePort = port
                preferences.claudeEnabled = true
            }
        #endif
        do {
            let store =
                options.inMemoryStore
                ? try PersistentStore.inMemory()
                : try PersistentStore.open(at: PersistentStore.defaultURL(name: options.storeName))
            var github = GitHubServices.live()
            #if DEBUG
                if options.demoGitHub { github = .demo() }
            #endif
            environment = AppEnvironment(store: store, github: github)
            startupError = nil
        } catch {
            // Typed throws: `error` is a PersistenceError.
            environment = nil
            startupError = error
        }
        github = GitHubModel(services: environment?.github)
        updates = UpdateModel(github: github, preferences: preferences, isDemo: options.demoGitHub)
        claude = ClaudeConnection(environment: environment, preferences: preferences, fixedKey: options.claudeKey)
    }

    func start() async {
        #if DEBUG
            if options.seedSampleData, let environment {
                do {
                    try await SampleData.seedIfEmpty(environment)
                } catch {
                    alert = AppAlert(title: "Couldn’t add sample data", error: error)
                }
            }
        #endif
        await loadProjects()
        claude.onTasksCreated = { [weak self] projectID in await self?.tasksChanged(in: projectID) }
        claude.apply()
        await github.loadStatus()
        if let notice = relaunchTicket.flatMap(UpdateModel.installedNotice) { alert = notice }
        #if DEBUG
            if options.startGitHubConnect && !github.isConnected { github.startConnecting() }
            if options.updateAtLaunch != nil {
                await updates.check(manual: true)
                if options.updateAtLaunch == "install", case .available(let update) = updates.phase {
                    try? await Task.sleep(for: .seconds(2))
                    await updates.install(update) { try await self.saveUpdateBackup(for: update.version) }
                }
            }
        #endif
    }

    func loadProjects() async {
        guard let environment else { return }
        do {
            groups = try await environment.groups.groups()
            projects = try await environment.store.projects.projects(includeArchived: true)
            for project in projects { await refreshStats(for: project.id) }
        } catch {
            alert = AppAlert(title: "Couldn’t load projects", error: error)
        }
        hasLoaded = true
    }

    /// Tasks were created outside the views (by Claude): the sidebar, the Dashboard, and an open workspace update.
    func tasksChanged(in projectID: UUID) async {
        await refreshStats(for: projectID)
        externalChange = ExternalChange(projectID: projectID)
    }

    func refreshStats(for projectID: UUID) async {
        guard let environment else { return }
        do {
            let state = try await environment.board.load(projectID: projectID)
            let plans = try await environment.releasePlans.plans(projectID: projectID)
            let snapshots = try await environment.store.releaseSnapshots.snapshots(projectID: projectID)
            stats[projectID] = ProjectStats(
                taskCount: state.tasks.count,
                completedCount: state.tasks.filter { $0.completedAt != nil }.count,
                activePlanVersion: plans.first(where: \.status.isActive)?.version,
                activePlan: plans.first(where: \.status.isActive),
                lastRelease: snapshots.filter { $0.state == .published }.max {
                    ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast)
                }
            )
        } catch {
            stats[projectID] = nil
        }
    }

    // MARK: Projects

    /// Throws so the editor can show validation messages inline.
    func createProject(name: String, details: String?, groupID: UUID?) async throws -> Project {
        guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
        let project = try await environment.projects.create(
            name: name, details: details, columns: preferences.newProjectColumns, groupID: groupID)
        projects.append(project)
        await refreshStats(for: project.id)
        return project
    }

    func updateProject(_ project: Project, name: String, details: String?, groupID: UUID?) async throws {
        guard let environment else { return }
        var edited = project
        edited.groupID = groupID
        replace(try await environment.projects.update(edited, name: name, details: details))
    }

    func setGroup(_ project: Project, _ groupID: UUID?) async {
        guard let environment else { return }
        do {
            replace(try await environment.projects.setGroup(project, groupID))
        } catch {
            alert = AppAlert(title: "Couldn’t move project", error: error)
        }
    }

    func setArchived(_ project: Project, _ archived: Bool) async {
        guard let environment else { return }
        do {
            replace(try await environment.projects.setArchived(project, archived))
        } catch {
            alert = AppAlert(title: archived ? "Couldn’t archive project" : "Couldn’t restore project", error: error)
        }
    }

    func deleteProject(_ project: Project) async {
        guard let environment else { return }
        do {
            try await environment.projects.delete(project.id)
            projects.removeAll { $0.id == project.id }
            stats[project.id] = nil
        } catch {
            alert = AppAlert(title: "Couldn’t delete project", error: error)
        }
    }

    // MARK: Groups

    /// Throws so the editor can show validation messages inline. Moves `project`, if given, into the new group.
    @discardableResult
    func createGroup(name: String, moving project: Project? = nil) async throws -> ProjectGroup {
        guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
        let group = try await environment.groups.create(name: name)
        groups.append(group)
        if let project { await setGroup(project, group.id) }
        return group
    }

    func renameGroup(_ group: ProjectGroup, to name: String) async throws {
        guard let environment else { return }
        let renamed = try await environment.groups.rename(group, to: name)
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = renamed }
    }

    /// Moves a group up (`-1`) or down (`1`) in the sidebar.
    func moveGroup(_ group: ProjectGroup, by offset: Int) async {
        guard let environment, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        do {
            groups = try await environment.groups.move(group.id, to: index + offset)
        } catch {
            alert = AppAlert(title: "Couldn’t move group", error: error)
        }
    }

    /// Deletes the group only; its projects stay, outside any group.
    func deleteGroup(_ group: ProjectGroup) async {
        guard let environment else { return }
        do {
            try await environment.groups.delete(group.id)
            groups.removeAll { $0.id == group.id }
            for index in projects.indices where projects[index].groupID == group.id { projects[index].groupID = nil }
        } catch {
            alert = AppAlert(title: "Couldn’t delete group", error: error)
        }
    }

    // MARK: Release history

    func loadHistory() async {
        guard let environment else { return }
        do {
            releaseHistory = try await environment.store.releaseSnapshots.allSnapshots()
        } catch {
            alert = AppAlert(title: "Couldn’t load release history", error: error)
        }
    }

    func showInHistory(_ snapshotID: UUID) {
        historySelection = snapshotID
        navigationRequest = .history
    }

    /// Opens a project, optionally on a tab and with an action such as starting a new task.
    func openProject(_ id: UUID, tab: WorkspaceTab? = nil, action: WorkspaceRequest.Action? = nil) {
        navigationRequest = .project(id)
        if tab != nil || action != nil { workspaceRequest = WorkspaceRequest(projectID: id, tab: tab, action: action) }
    }

    private func replace(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
    }

    // MARK: Backup

    func beginBackupExport() async {
        guard let environment else { return }
        do {
            let document = try await environment.backups.export(
                appVersion: Self.appVersion, preferences: preferences.record)
            backupToExport = BackupFile(data: try document.encoded())
            isExportingBackup = true
        } catch {
            alert = AppAlert(title: "Couldn’t create backup", error: error)
        }
    }

    func finishBackupExport(_ result: Result<URL, any Error>) {
        backupToExport = nil
        if case .failure(let error) = result {
            alert = AppAlert(title: "Couldn’t save backup", error: error)
        }
    }

    /// Reads and validates the chosen file; nothing changes until the user confirms.
    func inspectBackup(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let (document, summary) = try BackupService.inspect(try Data(contentsOf: url))
            pendingRestore = PendingRestore(fileName: url.lastPathComponent, document: document, summary: summary)
        } catch {
            alert = AppAlert(title: "Can’t restore this file", error: error)
        }
    }

    /// Saves a safety copy of the current data, then replaces everything with the backup.
    func confirmRestore() async {
        guard let pending = pendingRestore, let environment else { return }
        pendingRestore = nil
        do {
            let safetyURL = try await saveSafetyBackup(named: "Before restore")

            let summary = try await environment.backups.restore(pending.document)
            if let record = pending.document.preferences { preferences.apply(record) }
            dataVersion += 1
            await loadProjects()
            alert = AppAlert(
                title: "Backup restored",
                message: "Restored \(summary.projectCount) projects and \(summary.taskCount) tasks. "
                    + "Your previous data was saved as “\(safetyURL.lastPathComponent)”.",
                revealURL: safetyURL
            )
        } catch {
            alert = AppAlert(title: "Couldn’t restore backup", error: error)
        }
    }

    /// A backup of all data before an update: a newer version can change the data so this one can't open it.
    func saveUpdateBackup(for version: SemanticVersion) async throws -> URL {
        try await saveSafetyBackup(named: "Before updating to \(version)")
    }

    /// Saves all data and settings in Safety Backups as "<name> <timestamp>.json".
    private func saveSafetyBackup(named name: String) async throws -> URL {
        guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
        let document = try await environment.backups.export(
            appVersion: Self.appVersion, preferences: preferences.record)
        let url = try Self.safetyBackupURL(named: name)
        try document.encoded().write(to: url, options: .atomic)
        return url
    }

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var backupFileName: String {
        "Relvora Backup \(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private static func safetyBackupURL(named name: String) throws -> URL {
        let folder = URL.applicationSupportDirectory
            .appending(path: "Relvora", directoryHint: .isDirectory)
            .appending(path: "Safety Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return folder.appending(path: "\(name) \(stamp).json")
    }
}
