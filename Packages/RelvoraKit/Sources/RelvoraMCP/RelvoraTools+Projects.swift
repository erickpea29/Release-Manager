import Foundation
import RelvoraCore

/// A project's board columns, and projects themselves: creating, editing, archiving, and grouping (ADR 0026). Claude
/// can't delete projects or groups.
extension RelvoraTools {
    private static let columnProperty: JSONValue = [
        "type": "string", "description": "The column's name, from list_projects.",
    ]
    private static let positionProperty: JSONValue = [
        "type": "integer", "minimum": 1, "description": "Where it goes on the board: 1 is the first column.",
    ]

    private func column(_ argument: JSONValue?, in state: BoardState, project: Project) throws -> BoardColumn {
        guard let name = argument?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError("Name the column, from list_projects.")
        }
        guard let column = BoardState.column(named: name, in: state.orderedColumns) else {
            throw ToolError(
                "\(project.name) has no column “\(name)”. The columns are \(Self.list(state.orderedColumns.map(\.name)))."
            )
        }
        return column
    }

    private static func columnsResult(_ state: BoardState, summary: String) -> JSONValue {
        [
            "columns": .array(state.orderedColumns.map { .string($0.name) }),
            "completionColumn": state.orderedColumns.first(where: \.isCompletionColumn).map { .string($0.name) }
                ?? .null,
            "summary": .string(summary),
        ]
    }

    // MARK: add_column

    var addColumn: MCPTool {
        MCPTool(
            name: "add_column", title: "Add a board column",
            description: """
                Adds a column to a project's board, which every version of the project uses. It goes before the \
                completion column unless a position is given.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "name": [
                        "type": "string", "maxLength": .integer(BoardPlanner.maximumColumnNameLength),
                    ],
                    "position": Self.positionProperty,
                ],
                "required": ["project", "name"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                guard let name = try Self.string(arguments, "name") else { throw ToolError("Give the column a name.") }
                let before = try await board.load(projectID: project.id)
                if BoardState.column(named: name, in: before.columns) != nil {
                    throw ToolError("\(project.name) already has a column named “\(name)”.")
                }
                let position = try Self.integer(arguments, "position")
                var state = try await board.addColumn(named: name, projectID: project.id)
                guard let added = state.columns.first(where: { old in !before.columns.contains { $0.id == old.id } })
                else { throw ToolError("Relvora couldn’t find the new column.") }
                if let position {
                    state = try await board.moveColumn(added.id, toIndex: position - 1, projectID: project.id)
                }
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .changed,
                        summary: "Claude added the column “\(added.name)” to \(project.name).", tab: "board"))
                return Self.columnsResult(state, summary: "Added “\(added.name)” to \(project.name)’s board.")
            }
        }
    }

    // MARK: update_column

    var updateColumn: MCPTool {
        MCPTool(
            name: "update_column", title: "Rename or move a board column",
            description: """
                Renames a column, moves it, or makes it the completion column. Making a column the completion \
                column marks its tasks done, and those in the old completion column not done.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "column": Self.columnProperty,
                    "name": [
                        "type": "string", "maxLength": .integer(BoardPlanner.maximumColumnNameLength),
                        "description": "A new name.",
                    ],
                    "position": Self.positionProperty,
                    "completion": ["type": "boolean", "description": "true makes it the completion column."],
                ],
                "required": ["project", "column"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                var state = try await board.load(projectID: project.id)
                let column = try column(arguments["column"], in: state, project: project)
                let name = try Self.string(arguments, "name")
                let position = try Self.integer(arguments, "position")
                let completion = try Self.bool(arguments, "completion")
                if completion == false {
                    throw ToolError("To change the completion column, make another column the completion column.")
                }
                guard name != nil || position != nil || completion != nil else {
                    throw ToolError("Nothing to change. Give name, position, or completion.")
                }
                if let name, let other = BoardState.column(named: name, in: state.columns), other.id != column.id {
                    throw ToolError("\(project.name) already has a column named “\(other.name)”.")
                }
                if let name { state = try await board.renameColumn(column.id, to: name, projectID: project.id) }
                if let position {
                    state = try await board.moveColumn(column.id, toIndex: position - 1, projectID: project.id)
                }
                if completion == true { state = try await board.makeCompletionColumn(column.id, projectID: project.id) }
                let now = state.column(column.id)?.name ?? column.name
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .changed,
                        summary: "Claude changed the column “\(now)” in \(project.name).", tab: "board"))
                return Self.columnsResult(state, summary: "Changed “\(now)” on \(project.name)’s board.")
            }
        }
    }

    // MARK: delete_column

    var deleteColumn: MCPTool {
        MCPTool(
            name: "delete_column", title: "Delete a board column",
            description: """
                Deletes a column from a project's board. Its tasks, if any, move to the end of moveTasksTo, which \
                is then required. The completion column and a board's last column can't be deleted. Do it only \
                when the user asked.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "column": Self.columnProperty,
                    "moveTasksTo": ["type": "string", "description": "The column its tasks move to."],
                ],
                "required": ["project", "column"], "additionalProperties": false,
            ],
            isReadOnly: false, isDestructive: true
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                let state = try await board.load(projectID: project.id)
                let column = try column(arguments["column"], in: state, project: project)
                let destination = try arguments["moveTasksTo"].flatMap { $0 == .null ? nil : $0 }.map {
                    try self.column($0, in: state, project: project)
                }
                let moved = state.tasks(in: column.id).count
                let after = try await board.deleteColumn(
                    column.id, movingTasksTo: destination?.id, projectID: project.id)
                let detail = destination.flatMap {
                    moved == 0 ? nil : "Its \(Self.count(moved, "task")) moved to “\($0.name)”."
                }
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .removed,
                        summary: "Claude deleted the column “\(column.name)” from \(project.name).", detail: detail,
                        tab: "board"))
                return Self.columnsResult(after, summary: "Deleted “\(column.name)”." + (detail.map { " \($0)" } ?? ""))
            }
        }
    }

    // MARK: create_project

    var createProject: MCPTool {
        MCPTool(
            name: "create_project", title: "Create a project",
            description: """
                Creates a project, with the board new projects start with (Settings › Board), in a group if one is \
                named. A group that doesn't exist yet is created.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "maxLength": .integer(ProjectRules.maximumNameLength)],
                    "description": ["type": "string"],
                    "group": ["type": "string", "description": "The group to list it under, such as a company."],
                ],
                "required": ["name"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run {
                guard let name = try Self.string(arguments, "name") else { throw ToolError("Give the project a name.") }
                // Checked before a new group is created for it.
                let trimmed = try ProjectRules.validatedName(name)
                if let existing = try await projects.projects(includeArchived: true).first(where: {
                    $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    throw ToolError(
                        "There’s already a project named “\(existing.name)”"
                            + (existing.isArchived ? " (archived)" : "") + ". Use it, or choose another name.")
                }
                let group = try await group(named: try Self.string(arguments, "group"))
                let project = try await ProjectService(repository: projects).create(
                    name: name, details: try Self.string(arguments, "description"),
                    columns: await newProjectColumns(), groupID: group?.group.id)
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .changed,
                        summary: "Claude created the project \(project.name)"
                            + (group.map { " in \($0.group.name)" } ?? "") + ".",
                        changedProject: true, tab: "board"))
                return try await projectResult(
                    project,
                    summary: "Created \(project.name)"
                        + (group.map { " in \($0.isNew ? "the new group " : "")\($0.group.name)" } ?? "") + ".")
            }
        }
    }

    /// The group named, created when there's none; `nil` for no name.
    private func group(named name: String?) async throws -> (group: ProjectGroup, isNew: Bool)? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let service = ProjectGroupService(repository: groups)
        if let existing = try await service.groups().first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return (existing, false)
        }
        return (try await service.create(name: name), true)
    }

    private func projectResult(_ project: Project, summary: String) async throws -> JSONValue {
        let state = try await board.load(projectID: project.id)
        let group = project.groupID == nil ? nil : try await groups.groups().first { $0.id == project.groupID }
        var item: [String: JSONValue] = [
            "id": .string(project.id.uuidString), "name": .string(project.name),
            "group": group.map { .string($0.name) } ?? .null, "archived": .bool(project.isArchived),
            "columns": .array(state.orderedColumns.map { .string($0.name) }),
        ]
        if let details = project.details { item["description"] = .string(details) }
        return ["project": .object(item), "summary": .string(summary)]
    }

    // MARK: update_project

    var updateProject: MCPTool {
        MCPTool(
            name: "update_project", title: "Edit, group, or archive a project",
            description: """
                Renames a project, changes its description, lists it under a group (created if new; empty text \
                takes it out of its group), or archives or unarchives it. Archived projects keep everything but \
                leave the sidebar, and can't be changed until unarchived.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "name": ["type": "string", "maxLength": .integer(ProjectRules.maximumNameLength)],
                    "description": ["type": "string", "description": "Empty text clears it."],
                    "group": ["type": "string", "description": "A group's name; empty text for no group."],
                    "archived": ["type": "boolean"],
                ],
                "required": ["project"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run { try await editProject(arguments) }
        }
    }

    private func editProject(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let original = try await project(arguments["project"])
        let name = try Self.string(arguments, "name")
        let description = try Self.string(arguments, "description")
        let groupName = try Self.string(arguments, "group")
        let archived = try Self.bool(arguments, "archived")
        guard name != nil || description != nil || groupName != nil || archived != nil else {
            throw ToolError("Nothing to change. Give name, description, group, or archived.")
        }
        if original.isArchived, archived != false, name != nil || description != nil || groupName != nil {
            throw Self.archived(original)
        }
        if let name { _ = try ProjectRules.validatedName(name) }  // Before a new group is created.
        let service = ProjectService(repository: projects)
        var project = original
        if name != nil || description != nil || groupName != nil {
            if let groupName { project.groupID = try await group(named: groupName)?.group.id }
            project = try await service.update(
                project, name: name ?? project.name, details: description ?? project.details)
        }
        let edited = project != original
        if let archived { project = try await service.setArchived(project, archived) }
        let archiving = project.isArchived != original.isArchived
        guard edited || archiving else { return try await projectResult(project, summary: "Nothing changed.") }
        let summary =
            edited
            ? "Claude edited the project \(project.name)\(archiving ? " and \(project.isArchived ? "archived" : "unarchived") it" : "")."
            : "Claude \(project.isArchived ? "archived" : "unarchived") \(project.name)."
        await didChange(
            Activity(
                projectID: project.id, projectName: project.name, kind: .changed, summary: summary,
                changedProject: true, tab: "board"))
        return try await projectResult(project, summary: "Saved \(project.name).")
    }
}
