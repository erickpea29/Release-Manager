import AppIntents
import Foundation
import RelvoraWidgetData

/// The widget's settings: one project, or none for every project.
struct ProjectWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Next Release"
    static let description = IntentDescription("Shows the version being planned in one project, or in every project.")

    @Parameter(title: "Project", description: "Leave it empty to show every project.")
    var project: ProjectEntity?

    init() {}
}

/// A project the widget can show, from the snapshot the app wrote. The widget's own type: it never opens the store.
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectEntityQuery()

    let id: UUID
    let name: String
    let groupName: String?
    let iconName: String

    init(_ project: WidgetSnapshot.ProjectEntry) {
        id = project.id
        name = project.name
        groupName = project.groupName
        iconName = project.iconName
    }

    /// A project the snapshot no longer has (deleted or archived): the widget says so.
    init(missing id: UUID) {
        self.id = id
        name = String(localized: "Project not found")
        groupName = nil
        iconName = "questionmark.folder"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: groupName.map { "\($0)" }, image: .init(systemName: iconName))
    }
}

struct ProjectEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
        let snapshot = WidgetSnapshotStore.shared()?.read()
        return identifiers.map { id in snapshot?.project(id).map(ProjectEntity.init) ?? ProjectEntity(missing: id) }
    }

    /// Active projects, in the sidebar's order.
    func suggestedEntities() async throws -> [ProjectEntity] {
        (WidgetSnapshotStore.shared()?.read()?.projects ?? []).map(ProjectEntity.init)
    }
}
