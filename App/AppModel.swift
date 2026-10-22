import Foundation
import Observation
import RelvoraCore
import RelvoraPersistence

/// Everything the UI depends on, built once at launch. Tests and previews build it from an in-memory store.
struct AppEnvironment: Sendable {
    let store: PersistentStore

    var createProject: CreateProject { CreateProject(repository: store.projects) }
}

/// Launch arguments, honored in Debug builds only, e.g. `-RelvoraInMemoryStore YES`.
struct LaunchOptions {
    var inMemoryStore = false
    var storeName = "Relvora"
    var seedSampleData = false

    static func current(_ defaults: UserDefaults = .standard) -> LaunchOptions {
        var options = LaunchOptions()
        #if DEBUG
            options.inMemoryStore = defaults.bool(forKey: "RelvoraInMemoryStore")
            options.storeName = defaults.string(forKey: "RelvoraStoreName") ?? options.storeName
            options.seedSampleData = defaults.bool(forKey: "RelvoraSeedSampleData")
        #endif
        return options
    }
}

/// A failed user action, presented as an alert.
struct OperationError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, error: any Error) {
        self.title = title
        self.message = [error.localizedDescription, (error as? any LocalizedError)?.recoverySuggestion]
            .compactMap(\.self)
            .joined(separator: " ")
    }
}

/// App-wide state shared by all views. Feature logic lives in RelvoraCore; this type only coordinates.
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var hasLoaded = false
    /// Set when the local store cannot be opened; the UI shows a recovery screen instead of content.
    let startupError: PersistenceError?
    var operationError: OperationError?
    var isPresentingNewProject = false

    let environment: AppEnvironment?
    private let options: LaunchOptions

    init(options: LaunchOptions = .current()) {
        self.options = options
        do {
            let store =
                options.inMemoryStore
                ? try PersistentStore.inMemory()
                : try PersistentStore.open(at: PersistentStore.defaultURL(name: options.storeName))
            environment = AppEnvironment(store: store)
            startupError = nil
        } catch {
            // Typed throws: `error` is a PersistenceError.
            environment = nil
            startupError = error
        }
    }

    func start() async {
        #if DEBUG
            if options.seedSampleData, let environment {
                do {
                    try await SampleData.seedIfEmpty(environment)
                } catch {
                    operationError = OperationError(title: "Couldn’t add sample data", error: error)
                }
            }
        #endif
        await loadProjects()
    }

    func loadProjects() async {
        guard let environment else { return }
        do {
            projects = try await environment.store.projects.projects(includeArchived: false)
        } catch {
            operationError = OperationError(title: "Couldn’t load projects", error: error)
        }
        hasLoaded = true
    }

    /// Throws so the caller can show validation messages inline.
    func createProject(name: String, details: String?) async throws -> Project {
        guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
        let project = try await environment.createProject(name: name, details: details)
        projects.append(project)
        return project
    }

    func columns(for projectID: UUID) async throws -> [BoardColumn] {
        guard let environment else { return [] }
        return try await environment.store.board.columns(projectID: projectID)
    }
}
