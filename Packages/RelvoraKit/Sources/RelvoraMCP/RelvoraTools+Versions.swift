import Foundation
import RelvoraCore

/// Versions (release plans): listing, planning, editing, ticking the release checklist, cancelling, and deleting
/// (ADR 0026). Drafts, publishing, and everything else on GitHub stay with the user.
extension RelvoraTools {
    private static let versionProperty: JSONValue = [
        "type": "string", "description": "The version, such as 0.3.1, or its id from list_versions.",
    ]

    // MARK: list_versions

    var listVersions: MCPTool {
        MCPTool(
            name: "list_versions", title: "List a project's versions",
            description: """
                A project's versions (release plans), newest first: the one being planned, published releases, and \
                cancelled ones, with their status, dates, notes, task counts, and what can still be changed. The \
                version being planned also has its release checklist.
                """,
            inputSchema: [
                "type": "object", "properties": ["project": Self.projectProperty], "required": ["project"],
                "additionalProperties": false,
            ],
            isReadOnly: true
        ) { arguments in
            await Self.run {
                let project = try await project(arguments["project"])
                let state = try await board.load(projectID: project.id)
                let steps = try await checklist.steps(projectID: project.id)
                let all = try await plans.plans(projectID: project.id).sorted { $0.createdAt > $1.createdAt }
                return [
                    "project": .string(project.name),
                    "versions": .array(all.map { Self.json($0, board: state, steps: steps) }),
                ]
            }
        }
    }

    static func json(_ plan: ReleasePlan, board: BoardState, steps: [ReleaseStep]) -> JSONValue {
        let tasks = board.tasks.filter { $0.releasePlanID == plan.id }
        guard case .object(var item) = json(plan, tasks: tasks.count, done: tasks.count { $0.completedAt != nil })
        else { return .null }
        item["beingPlanned"] = .bool(plan.status.isActive)
        item["canEdit"] = .bool(ReleasePlanRules.isEditable(plan))
        item["canDelete"] = .bool(ReleasePlanRules.isDeletable(plan))
        if let notes = plan.details { item["notes"] = .string(notes) }
        if let date = plan.releasedAt { item["releasedAt"] = .string(day(date)) }
        if plan.status.isActive, !steps.isEmpty {
            item["releaseChecklist"] = .array(
                steps.map { ["step": .string($0.title), "done": .bool(plan.completedStepIDs.contains($0.id))] })
        }
        return .object(item)
    }

    /// A version of `project`, by version or id; the version being planned when `argument` is absent and `required`
    /// is false.
    private func plan(_ argument: JSONValue?, of project: Project, required: Bool) async throws -> ReleasePlan {
        let all = try await plans.plans(projectID: project.id)
        guard let text = argument?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if required { throw ToolError("Name the version, such as 0.3.1, from list_versions.") }
            guard let active = all.first(where: \.status.isActive) else {
                throw ToolError("\(project.name) has no version being planned. Name one from list_versions.")
            }
            return active
        }
        if let id = UUID(uuidString: text), let plan = all.first(where: { $0.id == id }) { return plan }
        let wanted = try? ReleaseVersion(parsing: text)
        let matches = all.filter {
            $0.version.caseInsensitiveCompare(text) == .orderedSame
                || (wanted != nil && (try? ReleaseVersion(parsing: $0.version)) == wanted)
        }
        // A cancelled plan can share its version with a newer one: the newer one wins.
        let live = matches.filter { $0.status != .cancelled }
        if let only = (live.count == 1 ? live.first : nil) ?? (matches.count == 1 ? matches.first : nil) {
            return only
        }
        if matches.isEmpty {
            throw ToolError(
                "\(project.name) has no version \(text). Versions: \(Self.list(all.map(\.version))).")
        }
        throw ToolError("\(project.name) has more than one \(text). Use its id from list_versions.")
    }

    private func versionResult(_ plan: ReleasePlan, project: Project, summary: String) async throws -> JSONValue {
        let state = try await board.load(projectID: project.id)
        let steps = try await checklist.steps(projectID: project.id)
        return ["version": Self.json(plan, board: state, steps: steps), "summary": .string(summary)]
    }

    // MARK: plan_version

    var planVersion: MCPTool {
        MCPTool(
            name: "plan_version", title: "Plan a version",
            description: """
                Starts planning a new version of a project, which becomes the version being planned: its Board \
                shows its tasks. A project plans one version at a time, so this is refused while another is being \
                planned. Move Backlog tasks into it with update_tasks (version "version").
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "version": [
                        "type": "string",
                        "description": "A semantic version such as 0.3.1 or 2.0.0-beta.1, or a short label.",
                    ],
                    "title": [
                        "type": "string", "maxLength": .integer(ReleasePlanRules.maximumTitleLength),
                        "description": "A short name, shown after the version on GitHub.",
                    ],
                    "notes": ["type": "string", "description": "What the version is about."],
                    "plannedDate": ["type": "string", "description": "The day it's planned for, like 2026-11-20."],
                ],
                "required": ["project", "version"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                guard let version = try Self.string(arguments, "version") else {
                    throw ToolError("Give the version, such as 0.3.1.")
                }
                let plan = try await plans.create(
                    projectID: project.id, version: version, title: try Self.string(arguments, "title"),
                    details: try Self.string(arguments, "notes"),
                    plannedDate: try Self.string(arguments, "plannedDate").map(Self.day))
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .changed,
                        summary: "Claude planned \(project.name) \(plan.version).", tab: "releases"))
                return try await versionResult(
                    plan, project: project, summary: "\(project.name) \(plan.version) is now being planned.")
            }
        }
    }

    // MARK: update_version

    var updateVersion: MCPTool {
        MCPTool(
            name: "update_version", title: "Edit a version",
            description: """
                Changes a version that's still planned: its version, title, notes, or planned date, and ticks or \
                unticks steps of its release checklist. Give only what changes; empty text clears a field. A \
                version with a draft on GitHub, published, or cancelled can't be changed.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "project": Self.projectProperty,
                    "version": [
                        "type": "string",
                        "description": "The version to change, or its id. Default: the version being planned.",
                    ],
                    "newVersion": ["type": "string", "description": "A new version, such as 0.4.0."],
                    "title": [
                        "type": "string", "maxLength": .integer(ReleasePlanRules.maximumTitleLength),
                    ],
                    "notes": ["type": "string"],
                    "plannedDate": ["type": "string", "description": "Like 2026-11-20."],
                    "releaseChecklist": [
                        "type": "array",
                        "description": "Steps of the project's release checklist (from list_versions) to tick or untick.",
                        "items": [
                            "type": "object",
                            "properties": ["step": ["type": "string"], "done": ["type": "boolean"]],
                            "required": ["step", "done"], "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["project"], "additionalProperties": false,
            ],
            isReadOnly: false
        ) { arguments in
            await Self.run { try await editVersion(arguments) }
        }
    }

    private func editVersion(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let project = try await changeableProject(arguments["project"])
        let original = try await plan(arguments["version"], of: project, required: false)
        guard ReleasePlanRules.isEditable(original) else {
            throw ToolError(
                "\(project.name) \(original.version) is \(original.status.title.lowercased()), so it can no longer "
                    + "be changed.")
        }
        var plan = original
        if let version = try Self.string(arguments, "newVersion") { plan.version = version }
        if let title = try Self.string(arguments, "title") { plan.title = title }
        if let notes = try Self.string(arguments, "notes") { plan.details = notes }
        if let date = try Self.string(arguments, "plannedDate") {
            plan.plannedDate = date.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try Self.day(date)
        }
        if let ticks = arguments["releaseChecklist"], ticks != .null {
            let steps = try await checklist.steps(projectID: project.id)
            for tick in ticks.arrayValue ?? [] {
                guard let fields = tick.objectValue, let name = try Self.string(fields, "step"),
                    let done = try Self.bool(fields, "done")
                else { throw ToolError("Each releaseChecklist item needs a step and done.") }
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard
                    let step = steps.first(where: {
                        $0.title.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                            || $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame
                    })
                else {
                    throw ToolError(
                        "\(project.name)’s release checklist has no step “\(name)”. Steps: "
                            + "\(Self.list(steps.map(\.title))).")
                }
                if done { plan.completedStepIDs.insert(step.id) } else { plan.completedStepIDs.remove(step.id) }
            }
        }
        guard plan != original else {
            throw ToolError("Nothing to change. Give newVersion, title, notes, plannedDate, or releaseChecklist.")
        }
        let saved = try await plans.update(plan)
        await didChange(
            Activity(
                projectID: project.id, projectName: project.name, kind: .changed,
                summary: "Claude edited \(project.name) \(saved.version).", tab: "releases"))
        return try await versionResult(saved, project: project, summary: "Saved \(project.name) \(saved.version).")
    }

    // MARK: cancel_version

    var cancelVersion: MCPTool {
        MCPTool(
            name: "cancel_version", title: "Cancel a version",
            description: """
                Cancels a version that's still planned: it stays in the list as cancelled, and its unfinished tasks \
                go back to the Backlog. This can't be undone (a new version can be planned instead). Do it only \
                when the user asked.
                """,
            inputSchema: [
                "type": "object",
                "properties": ["project": Self.projectProperty, "version": Self.versionProperty],
                "required": ["project", "version"], "additionalProperties": false,
            ],
            isReadOnly: false, isDestructive: true
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                let plan = try await plan(arguments["version"], of: project, required: true)
                guard ReleasePlanRules.isEditable(plan) else {
                    throw ToolError(
                        "\(project.name) \(plan.version) is \(plan.status.title.lowercased()), so it can’t be "
                            + "cancelled. Its draft is on GitHub: ask the user to handle it in Relvora.")
                }
                let cancelled = try await plans.cancel(plan)
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .removed,
                        summary: "Claude cancelled \(project.name) \(plan.version).",
                        detail: "Its unfinished tasks are in the Backlog.", tab: "releases"))
                return try await versionResult(
                    cancelled, project: project, summary: "Cancelled \(project.name) \(plan.version).")
            }
        }
    }

    // MARK: delete_version

    var deleteVersion: MCPTool {
        MCPTool(
            name: "delete_version", title: "Delete a version",
            description: """
                Deletes a planned or cancelled version for good. Its tasks stay, outside any version (unfinished \
                ones in the Backlog). Published versions and versions with a draft on GitHub are kept as a record. \
                This can't be undone: do it only when the user asked.
                """,
            inputSchema: [
                "type": "object",
                "properties": ["project": Self.projectProperty, "version": Self.versionProperty],
                "required": ["project", "version"], "additionalProperties": false,
            ],
            isReadOnly: false, isDestructive: true
        ) { arguments in
            await Self.run {
                let project = try await changeableProject(arguments["project"])
                let plan = try await plan(arguments["version"], of: project, required: true)
                guard ReleasePlanRules.isDeletable(plan) else {
                    throw ToolError(
                        "\(project.name) \(plan.version) is \(plan.status.title.lowercased()), so it’s kept as a "
                            + "record and can’t be deleted.")
                }
                let tasks = try await board.load(projectID: project.id).tasks.count { $0.releasePlanID == plan.id }
                try await plans.delete(plan)
                await didChange(
                    Activity(
                        projectID: project.id, projectName: project.name, kind: .removed,
                        summary: "Claude deleted \(project.name) \(plan.version).",
                        detail: tasks == 0 ? nil : "Its \(Self.count(tasks, "task")) stayed, outside any version.",
                        tab: "releases"))
                return [
                    "summary": .string(
                        "Deleted \(project.name) \(plan.version). "
                            + (tasks == 0 ? "It had no tasks." : "Its \(Self.count(tasks, "task")) stayed.")),
                ]
            }
        }
    }
}
