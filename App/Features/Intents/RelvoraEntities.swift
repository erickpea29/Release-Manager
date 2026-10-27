import AppIntents
import CoreSpotlight
import Foundation
import RelvoraCore
import UniformTypeIdentifiers

/// A project in Shortcuts and Spotlight (ADR 0023). Archived projects aren't offered.
struct ProjectEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = ProjectQuery()

    let id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Group") var group: String?
    @Property(title: "Description") var details: String?
    @Property(title: "Version Being Planned") var version: String?

    init(_ project: SearchableProject) {
        id = project.id
        name = project.name
        group = project.groupName
        details = project.details
        version = project.version
    }

    private var searchable: SearchableProject {
        SearchableProject(id: id, name: name, details: details, groupName: group, version: version)
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = searchable.subtitle
        return DisplayRepresentation(
            title: "\(name)", subtitle: subtitle.isEmpty ? nil : "\(subtitle)", image: .init(systemName: "shippingbox"))
    }

    var attributeSet: CSSearchableItemAttributeSet { SpotlightIndex.attributes(.project(searchable)) }
}

/// A task on a Board or in a Backlog, in Shortcuts and Spotlight. Finished tasks of past versions aren't offered.
struct TaskEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static let defaultQuery = TaskQuery()

    let id: UUID
    let projectID: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Project") var project: String
    @Property(title: "Notes") var notes: String?
    @Property(title: "Labels") var labels: [String]
    @Property(title: "Type") var type: TaskTypeOption
    @Property(title: "Priority") var priority: TaskPriorityOption
    @Property(title: "Column") var column: String?
    @Property(title: "Version") var version: String?
    @Property(title: "Done") var isDone: Bool

    init(_ task: SearchableTask) {
        id = task.id
        projectID = task.projectID
        title = task.title
        project = task.projectName
        notes = task.notes
        labels = task.labels
        type = TaskTypeOption(task.type)
        priority = TaskPriorityOption(task.priority)
        column = task.column
        version = task.version
        isDone = task.isDone
    }

    private var searchable: SearchableTask {
        SearchableTask(
            id: id, projectID: projectID, projectName: project, title: title, notes: notes, labels: labels,
            type: type.type, priority: priority.priority, column: column, version: version, isDone: isDone)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)", subtitle: "\(searchable.subtitle)",
            image: .init(systemName: isDone ? "checkmark.circle" : "circle"))
    }

    var attributeSet: CSSearchableItemAttributeSet { SpotlightIndex.attributes(.task(searchable)) }
}

/// A project's version being planned and its progress: what "What's the next release of …" returns.
struct ReleaseEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Release")
    static let defaultQuery = ReleaseQuery()

    let id: UUID
    @Property(title: "Project") var project: String
    @Property(title: "Version") var version: String
    @Property(title: "Title") var title: String?
    @Property(title: "Status") var status: String
    @Property(title: "Tasks Done") var tasksDone: Int
    @Property(title: "Tasks") var tasks: Int
    @Property(title: "Planned Date") var plannedDate: Date?
    @Property(title: "Summary") var summary: String

    init(projectName: String, progress: VersionProgress) {
        id = progress.plan.id
        project = projectName
        version = progress.plan.version
        title = progress.plan.title
        status = progress.plan.status.title
        tasksDone = progress.done
        tasks = progress.total
        plannedDate = progress.plan.plannedDate
        summary = progress.summary(projectName: projectName)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(project) \(version)", subtitle: "\(status) · \(tasksDone) of \(tasks) done",
            image: .init(systemName: "shippingbox"))
    }
}

// MARK: Queries

/// Active projects in sidebar order, found by name, description, or group.
struct ProjectQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
        try await projects().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        try await projects().filter { TextSearch.matches(string, fields: [$0.name, $0.details, $0.group]) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        try await projects()
    }

    private func projects() async throws -> [ProjectEntity] {
        try await app.searchableItems().compactMap {
            if case .project(let project) = $0 { ProjectEntity(project) } else { nil }
        }
    }
}

/// Tasks on the Boards and in the Backlogs of active projects, found by title, notes, labels, or project.
struct TaskQuery: EntityStringQuery {
    static let maximumResults = 50

    @Dependency private var app: AppModel

    func entities(for identifiers: [UUID]) async throws -> [TaskEntity] {
        try await tasks().filter { identifiers.contains($0.id) }.map(TaskEntity.init)
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        try await tasks().filter { $0.matches(string) }.prefix(Self.maximumResults).map(TaskEntity.init)
    }

    /// The unfinished tasks of the versions being planned.
    func suggestedEntities() async throws -> [TaskEntity] {
        try await tasks().filter { $0.isOnBoard && !$0.isDone }.prefix(Self.maximumResults).map(TaskEntity.init)
    }

    private func tasks() async throws -> [SearchableTask] {
        try await app.searchableItems().compactMap {
            if case .task(let task) = $0 { task } else { nil }
        }
    }
}

/// The versions being planned in active projects.
struct ReleaseQuery: EntityQuery {
    @Dependency private var app: AppModel

    func entities(for identifiers: [UUID]) async throws -> [ReleaseEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ReleaseEntity] {
        try await app.activeProjectContents().compactMap { contents in
            VersionProgress(plans: contents.plans, board: contents.board).map {
                ReleaseEntity(projectName: contents.project.name, progress: $0)
            }
        }
    }
}

// MARK: Options

enum TaskTypeOption: String, AppEnum {
    case feature, improvement, bugFix, documentation, maintenance, other

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task Type")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .feature: "Feature",
        .improvement: "Improvement",
        .bugFix: "Bug Fix",
        .documentation: "Documentation",
        .maintenance: "Maintenance",
        .other: "Other",
    ]

    init(_ type: TaskType) {
        self = Self(rawValue: type.rawValue) ?? .other
    }

    var type: TaskType { TaskType(rawValue: rawValue) ?? .other }
}

enum TaskPriorityOption: String, AppEnum {
    case low, medium, high, urgent

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Priority")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .urgent: "Urgent",
    ]

    init(_ priority: TaskPriority) {
        self = Self(rawValue: priority.rawValue) ?? .medium
    }

    var priority: TaskPriority { TaskPriority(rawValue: rawValue) ?? .medium }
}

/// Where Add a Task puts the task.
enum TaskPlaceOption: String, AppEnum {
    case version, backlog

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Place")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .version: DisplayRepresentation(
            title: "Version Being Planned", subtitle: "Or the Backlog when no version is planned"),
        .backlog: "Backlog",
    ]

    var destination: TaskDestination { self == .backlog ? .backlog : .versionOrBacklog }
}
