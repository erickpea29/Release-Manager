import AppKit
import Foundation
import Observation
import RelvoraCore
import RelvoraPersistence

/// Everything the UI depends on, built once at launch. Previews and checks build it from an in-memory store.
struct AppEnvironment: Sendable {
    let store: PersistentStore
    let github: GitHubServices?

    var projects: ProjectService { ProjectService(repository: store.projects) }
    var board: BoardService { BoardService(repository: store.board) }
    var releasePlans: ReleasePlanService { ReleasePlanService(repository: store.releasePlans) }
    var backups: BackupService { BackupService(repository: store.backups) }
    var repositoryConnections: RepositoryConnectionService {
        RepositoryConnectionService(repository: store.repositoryConnections)
    }
}

/// Launch arguments, honored in Debug builds only, e.g. `-RelvoraInMemoryStore YES`.
struct LaunchOptions {
    var inMemoryStore = false
    var storeName = "Relvora"
    var seedSampleData = false
    /// Selects this project (by name) at launch; used for UI checks.
    var initialProjectName: String?
    var initialTab: String?
    /// Starts the GitHub device flow at launch (UI checks of the sign-in).
    var startGitHubConnect = false
    /// Connects this repository (`owner/name`) to the initial project once signed in.
    var connectRepository: String?

    static func current(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            options.inMemoryStore = defaults.bool(forKey: "RelvoraInMemoryStore")
            options.storeName = defaults.string(forKey: "RelvoraStoreName") ?? options.storeName
            options.seedSampleData = defaults.bool(forKey: "RelvoraSeedSampleData")
            options.initialProjectName = defaults.string(forKey: "RelvoraInitialProject")
            options.initialTab = defaults.string(forKey: "RelvoraInitialTab")
            options.startGitHubConnect = defaults.bool(forKey: "RelvoraStartGitHubConnect")
            options.connectRepository = defaults.string(forKey: "RelvoraConnectRepository")
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

    var progress: Double? { taskCount == 0 ? nil : Double(completedCount) / Double(taskCount) }
}

enum ProjectEditorRequest: Identifiable {
    case new
    case edit(Project)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let project): project.id.uuidString
        }
    }
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
    private(set) var stats: [UUID: ProjectStats] = [:]
    private(set) var hasLoaded = false
    /// Incremented after a restore so open views reload their data.
    private(set) var dataVersion = 0
    /// Set when the local store cannot be opened; the UI shows a recovery screen instead of content.
    let startupError: PersistenceError?

    var alert: AppAlert?
    var projectEditor: ProjectEditorRequest?
    var projectPendingDeletion: Project?
    var backupToExport: BackupFile?
    var isExportingBackup = false
    var isChoosingBackup = false
    var pendingRestore: PendingRestore?

    let environment: AppEnvironment?
    let options: LaunchOptions
    let github: GitHubModel

    var activeProjects: [Project] { projects.filter { !$0.isArchived } }
    var archivedProjects: [Project] { projects.filter(\.isArchived) }

    init(options: LaunchOptions = .current()) {
        self.options = options
        do {
            let store =
                options.inMemoryStore
                ? try PersistentStore.inMemory()
                : try PersistentStore.open(at: PersistentStore.defaultURL(name: options.storeName))
            environment = AppEnvironment(store: store, github: GitHubServices.live())
            startupError = nil
        } catch {
            // Typed throws: `error` is a PersistenceError.
            environment = nil
            startupError = error
        }
        github = GitHubModel(services: environment?.github)
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
        await github.loadStatus()
        #if DEBUG
            if options.startGitHubConnect && !github.isConnected { github.startConnecting() }
        #endif
    }

    func loadProjects() async {
        guard let environment else { return }
        do {
            projects = try await environment.store.projects.projects(includeArchived: true)
            for project in projects { await refreshStats(for: project.id) }
        } catch {
            alert = AppAlert(title: "Couldn’t load projects", error: error)
        }
        hasLoaded = true
    }

    func refreshStats(for projectID: UUID) async {
        guard let environment else { return }
        do {
            let state = try await environment.board.load(projectID: projectID)
            let plans = try await environment.releasePlans.plans(projectID: projectID)
            stats[projectID] = ProjectStats(
                taskCount: state.tasks.count,
                completedCount: state.tasks.filter { $0.completedAt != nil }.count,
                activePlanVersion: plans.first(where: \.status.isActive)?.version
            )
        } catch {
            stats[projectID] = nil
        }
    }

    // MARK: Projects

    /// Throws so the editor can show validation messages inline.
    func createProject(name: String, details: String?) async throws -> Project {
        guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
        let project = try await environment.projects.create(name: name, details: details)
        projects.append(project)
        await refreshStats(for: project.id)
        return project
    }

    func updateProject(_ project: Project, name: String, details: String?) async throws {
        guard let environment else { return }
        replace(try await environment.projects.update(project, name: name, details: details))
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

    private func replace(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) { projects[index] = project }
    }

    // MARK: Backup

    func beginBackupExport() async {
        guard let environment else { return }
        do {
            let document = try await environment.backups.export(appVersion: Self.appVersion)
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
            let safety = try await environment.backups.export(appVersion: Self.appVersion)
            let safetyURL = try Self.safetyBackupURL()
            try safety.encoded().write(to: safetyURL, options: .atomic)

            let summary = try await environment.backups.restore(pending.document)
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

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var backupFileName: String {
        "Relvora Backup \(Date.now.formatted(.iso8601.year().month().day()))"
    }

    private static func safetyBackupURL() throws -> URL {
        let folder = URL.applicationSupportDirectory
            .appending(path: "Relvora", directoryHint: .isDirectory)
            .appending(path: "Safety Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return folder.appending(path: "Before restore \(stamp).json")
    }
}
