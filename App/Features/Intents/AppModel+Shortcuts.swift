import AppIntents
import AppKit
import CoreSpotlight
import Foundation
import RelvoraCore
import SwiftUI

/// A problem Shortcuts or Siri shows: what went wrong and what to do.
struct ShortcutsError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// One active project's contents, read for Spotlight and Shortcuts.
struct ProjectContents {
    let project: Project
    let groupName: String?
    let board: BoardState
    let plans: [ReleasePlan]
}

extension AppEnvironment {
    /// Every active project with its board and plans, in sidebar order.
    func activeProjectContents() async throws -> [ProjectContents] {
        let groups = try await self.groups.groups()
        let names = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        let projects = try await store.projects.projects(includeArchived: false)
        var contents: [ProjectContents] = []
        for project in ProjectGrouping.sections(projects, groups: groups).flatMap(\.projects) {
            contents.append(
                ProjectContents(
                    project: project, groupName: project.groupID.flatMap { names[$0] },
                    board: try await board.load(projectID: project.id),
                    plans: try await releasePlans.plans(projectID: project.id)))
        }
        return contents
    }

    /// What Spotlight lists and Shortcuts offers: active projects, and their tasks on the Board and in the Backlog.
    func searchableItems() async throws -> [SearchableItem] {
        try await activeProjectContents().flatMap {
            SystemSearch.items($0.project, groupName: $0.groupName, board: $0.board, plans: $0.plans)
        }
    }
}

extension LaunchOptions {
    /// A copy run for tests or checks: a throwaway store or settings, sample data, or the demo GitHub. It never
    /// touches Spotlight or Siri, so test data stays out of the user's searches.
    var isTestCopy: Bool {
        inMemoryStore || seedSampleData || defaultsSuite != nil || demoGitHub || storeName != LaunchOptions().storeName
    }
}

/// What App Intents ask of the app (ADR 0023). They run in this process, on the same store as the window, so a task
/// added from Shortcuts appears on an open Board at once.
extension AppModel {
    /// Registers the model for the intents' `@Dependency`, before macOS runs any of them.
    func registerForIntents() {
        AppDependencyManager.shared.add(dependency: self)
    }

    /// Runs `work` with the store; its problems become messages Shortcuts and Siri can show.
    private func withStore<Value>(_ work: (AppEnvironment) async throws -> Value) async throws -> Value {
        do {
            guard let environment else { throw startupError ?? .storeUnavailable(reason: "No store") }
            return try await work(environment)
        } catch {
            throw ShortcutsError(message: AppAlert.message(for: error))
        }
    }

    func activeProjectContents() async throws -> [ProjectContents] {
        try await withStore { try await $0.activeProjectContents() }
    }

    func searchableItems() async throws -> [SearchableItem] {
        try await withStore { try await $0.searchableItems() }
    }

    /// Adds one task with the rules Claude's tasks follow, and refreshes what the window shows.
    func addTask(_ task: NewTask, to projectID: UUID, destination: TaskDestination) async throws -> (
        summary: String, task: SearchableTask?
    ) {
        let created = try await withStore { environment in
            let project = try await environment.store.projects.project(id: projectID)
            return try await TaskCreationService(board: environment.board, plans: environment.releasePlans)
                .create([task], in: project, destination: destination)
        }
        await dataChanged(in: projectID)
        let searchable = SystemSearch.tasks(
            of: created.project, board: created.board, plans: created.plan.map { [$0] } ?? []
        ).first { $0.id == created.tasks.first?.id }
        return (created.summary, searchable)
    }

    /// The project's name and its version being planned, if any.
    func nextRelease(of projectID: UUID) async throws -> (projectName: String, progress: VersionProgress?) {
        try await withStore { environment in
            let project = try await environment.store.projects.project(id: projectID)
            let progress = VersionProgress(
                plans: try await environment.releasePlans.plans(projectID: projectID),
                board: try await environment.board.load(projectID: projectID))
            return (project.name, progress)
        }
    }

    // MARK: Opening

    /// Opens a Spotlight result or an Open intent: the project on its Board, or a task's editor on the Board or in the
    /// Backlog. Relvora may have been opened for it, in which case the window follows the request once it appears.
    func open(_ target: SearchableItem.Target) async {
        NSApp.activate()
        let isShowingWindow = NSApp.windows.contains {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true
        }
        if hasLoaded, !isShowingWindow {
            // The window was closed: SwiftUI reopens it as for a click on the Dock icon.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
        switch target {
        case .project(let id):
            openProject(id, tab: .board)
        case .task(let id):
            guard let projectID = await projectID(ofTask: id) else { return }
            openProject(projectID, action: .openTask(id))
        }
    }

    /// A Spotlight result was clicked, and macOS handed it over as a user activity.
    func openSearchResult(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
            let target = SearchableItem.target(of: identifier)
        else { return }
        Task { await open(target) }
    }

    private func projectID(ofTask id: UUID) async -> UUID? {
        guard let environment, let projects = try? await environment.store.projects.projects(includeArchived: true)
        else { return nil }
        for project in projects {
            if let board = try? await environment.board.load(projectID: project.id), board.task(id) != nil {
                return project.id
            }
        }
        return nil
    }

    #if DEBUG
        /// `-RelvoraOpenSearchResult "task:<title>"` or `"project:<name>"`: opens it while Relvora opens, as a clicked
        /// Spotlight result that launched it would (UI tests; Spotlight itself can't be driven).
        func openSearchResultAtLaunch() async {
            guard let request = options.openSearchResult, let environment else { return }
            // The sample data is added first.
            for _ in 0..<100 where !hasLoaded { try? await Task.sleep(for: .milliseconds(100)) }
            let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let items = try? await environment.searchableItems() else { return }
            let match = items.first {
                switch $0 {
                case .project(let project): parts[0] == "project" && project.name == parts[1]
                case .task(let task): parts[0] == "task" && task.title == parts[1]
                }
            }
            if let match { await open(match.target) }
        }
    #endif
}

/// Opens Spotlight results that macOS hands over as a user activity.
struct OpensSearchResults: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onContinueUserActivity(CSSearchableItemActionType) { model.openSearchResult($0) }
    }
}
