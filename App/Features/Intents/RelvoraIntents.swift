import AppIntents
import Foundation
import RelvoraCore

/// Adds a task as the app's editor would: to the version being planned, or to the Backlog when none is planned or
/// the user chooses it. The same rules as Claude's `create_tasks` (`TaskCreationService`), without a label: the user
/// asked for it themselves.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let description = IntentDescription(
        "Adds a task to a project’s version being planned, or to its Backlog when no version is planned.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity

    @Parameter(title: "Title", requestValueDialog: "What’s the task?")
    var title: String

    @Parameter(title: "Type", default: .feature)
    var type: TaskTypeOption

    @Parameter(title: "Priority", default: .medium)
    var priority: TaskPriorityOption

    @Parameter(title: "Notes", inputOptions: String.IntentInputOptions(multiline: true))
    var notes: String?

    @Parameter(title: "Add To", default: .version)
    var place: TaskPlaceOption

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to \(\.$project)") {
            \.$place
            \.$type
            \.$priority
            \.$notes
        }
    }

    @Dependency private var app: AppModel

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity?> & ProvidesDialog {
        let added = try await app.addTask(
            NewTask(title: title, notes: notes, type: type.type, priority: priority.priority), to: project.id,
            destination: place.destination)
        return .result(value: added.task.map(TaskEntity.init), dialog: "\(added.summary)")
    }
}

/// "What's the next release of …": the version being planned, its status, its progress, and its planned date.
struct NextReleaseIntent: AppIntent {
    static let title: LocalizedStringResource = "Get the Next Release"
    static let description = IntentDescription(
        "The version a project is planning: its status, how many of its tasks are done, and its planned date.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the next release of \(\.$project)")
    }

    @Dependency private var app: AppModel

    func perform() async throws -> some IntentResult & ReturnsValue<ReleaseEntity?> & ProvidesDialog {
        let (name, progress) = try await app.nextRelease(of: project.id)
        guard let progress else {
            return .result(value: nil, dialog: "\(VersionProgress.nothingPlanned(projectName: name))")
        }
        let release = ReleaseEntity(projectName: name, progress: progress)
        return .result(value: release, dialog: "\(release.summary)")
    }
}

/// Opens a project in Relvora; Spotlight uses it for project results.
struct OpenProjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Project")
    var target: ProjectEntity

    @Dependency private var app: AppModel

    func perform() async throws -> some IntentResult {
        await app.open(.project(target.id))
        return .result()
    }
}

/// Opens a task's editor in Relvora, on the Board or in the Backlog; Spotlight uses it for task results.
struct OpenTaskIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Task"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Task")
    var target: TaskEntity

    @Dependency private var app: AppModel

    func perform() async throws -> some IntentResult {
        await app.open(.task(target.id))
        return .result()
    }
}

/// Phrases for Siri and Spotlight. Each names the app, as App Shortcuts require.
struct RelvoraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "Add a task in \(.applicationName)",
                "Add a \(.applicationName) task",
                "Add a task to \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Add a Task", systemImageName: "plus.circle")
        AppShortcut(
            intent: NextReleaseIntent(),
            phrases: [
                "What's the next release of \(\.$project) in \(.applicationName)",
                "What's the next release in \(.applicationName)",
                "Ask \(.applicationName) for the next release of \(\.$project)",
                "Next \(.applicationName) release of \(\.$project)",
            ],
            shortTitle: "Next Release", systemImageName: "shippingbox")
    }
}
