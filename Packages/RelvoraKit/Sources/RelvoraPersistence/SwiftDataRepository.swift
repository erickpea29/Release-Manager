import Foundation
import RelvoraCore
import SwiftData

/// SwiftData implementation of every repository protocol. A failed save rolls back the context, so
/// each public method is all-or-nothing.
actor SwiftDataRepository: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }

    // MARK: - Helpers

    private func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws(PersistenceError) -> [Model]
    {
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            Log.persistence.error("Fetch failed: \(String(describing: error), privacy: .private)")
            throw .fetchFailed(reason: String(describing: error))
        }
    }

    private func save() throws(PersistenceError) {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.persistence.error("Save failed: \(String(describing: error), privacy: .private)")
            throw .saveFailed(reason: String(describing: error))
        }
    }

    /// Discards unsaved changes before rethrowing, so a rejected operation leaves nothing behind.
    private func transaction(_ body: () throws(PersistenceError) -> Void) throws(PersistenceError) {
        do {
            try body()
            try save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func projectEntity(_ id: UUID) throws(PersistenceError) -> ProjectEntity {
        var descriptor = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let entity = try fetch(descriptor).first else { throw .notFound(entity: "project", id: id) }
        return entity
    }

    private func columnEntity(_ id: UUID) throws(PersistenceError) -> BoardColumnEntity? {
        var descriptor = FetchDescriptor<BoardColumnEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func taskEntity(_ id: UUID) throws(PersistenceError) -> TaskEntity? {
        var descriptor = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func planEntity(_ id: UUID) throws(PersistenceError) -> ReleasePlanEntity? {
        var descriptor = FetchDescriptor<ReleasePlanEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }
}

// MARK: - Projects

extension SwiftDataRepository: ProjectRepository {
    func projects(includeArchived: Bool) throws(PersistenceError) -> [Project] {
        let all = try fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.createdAt)]))
        return all.filter { includeArchived || $0.archivedAt == nil }.map(Project.init)
    }

    func project(id: UUID) throws(PersistenceError) -> Project {
        Project(try projectEntity(id))
    }

    func create(_ project: Project, columns: [BoardColumn]) throws(PersistenceError) {
        guard columns.allSatisfy({ $0.projectID == project.id }) else {
            throw .integrityViolation("Columns must belong to the project being created.")
        }
        try transaction { () throws(PersistenceError) in
            let entity = ProjectEntity(id: project.id, name: project.name, createdAt: project.createdAt)
            entity.apply(project)
            modelContext.insert(entity)
            for column in columns {
                let columnEntity = BoardColumnEntity(
                    id: column.id,
                    name: column.name,
                    sortOrder: column.sortOrder,
                    isCompletionColumn: column.isCompletionColumn,
                    createdAt: column.createdAt
                )
                modelContext.insert(columnEntity)
                columnEntity.project = entity
            }
        }
    }

    func update(_ project: Project) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            try projectEntity(project.id).apply(project)
        }
    }

    func deleteProject(id: UUID) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            modelContext.delete(try projectEntity(id))
        }
    }
}

// MARK: - Board

extension SwiftDataRepository: BoardRepository {
    func columns(projectID: UUID) throws(PersistenceError) -> [BoardColumn] {
        try projectEntity(projectID).columns.map(BoardColumn.init).sorted { $0.sortOrder < $1.sortOrder }
    }

    func tasks(projectID: UUID) throws(PersistenceError) -> [ProjectTask] {
        try projectEntity(projectID).tasks.compactMap(ProjectTask.init).sorted { $0.sortOrder < $1.sortOrder }
    }

    func save(_ column: BoardColumn) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            let project = try projectEntity(column.projectID)
            let entity: BoardColumnEntity
            if let existing = try columnEntity(column.id) {
                guard existing.project?.id == column.projectID else {
                    throw .integrityViolation("A column cannot move to another project.")
                }
                entity = existing
            } else {
                entity = BoardColumnEntity(
                    id: column.id,
                    name: column.name,
                    sortOrder: column.sortOrder,
                    isCompletionColumn: column.isCompletionColumn,
                    createdAt: column.createdAt
                )
                modelContext.insert(entity)
                entity.project = project
            }
            entity.name = column.name
            entity.sortOrder = column.sortOrder
            entity.isCompletionColumn = column.isCompletionColumn
            entity.updatedAt = column.updatedAt
        }
    }

    func save(_ task: ProjectTask) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            let project = try projectEntity(task.projectID)
            guard let column = try columnEntity(task.columnID), column.project?.id == task.projectID else {
                throw .integrityViolation("A task's column must belong to the task's project.")
            }
            var plan: ReleasePlanEntity?
            if let planID = task.releasePlanID {
                guard let found = try planEntity(planID), found.project?.id == task.projectID else {
                    throw .integrityViolation("A task's release plan must belong to the task's project.")
                }
                plan = found
            }

            let entity: TaskEntity
            if let existing = try taskEntity(task.id) {
                guard existing.project?.id == task.projectID else {
                    throw .integrityViolation("A task cannot move to another project.")
                }
                entity = existing
            } else {
                entity = TaskEntity(
                    id: task.id,
                    title: task.title,
                    priorityRaw: task.priority.rawValue,
                    typeRaw: task.type.rawValue,
                    sortOrder: task.sortOrder,
                    createdAt: task.createdAt
                )
                modelContext.insert(entity)
                entity.project = project
            }
            entity.apply(task)
            entity.column = column
            entity.releasePlan = plan
            syncChecklist(of: entity, to: task.checklist)
        }
    }

    func deleteTask(id: UUID) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            guard let entity = try taskEntity(id) else { throw .notFound(entity: "task", id: id) }
            modelContext.delete(entity)
        }
    }

    private func syncChecklist(of task: TaskEntity, to items: [ChecklistItem]) {
        let wanted = Set(items.map(\.id))
        for stale in task.checklist where !wanted.contains(stale.id) {
            modelContext.delete(stale)
        }
        let existing = Dictionary(
            uniqueKeysWithValues: task.checklist.filter { wanted.contains($0.id) }.map { ($0.id, $0) })
        for item in items {
            let entity =
                existing[item.id]
                ?? {
                    let created = ChecklistItemEntity(
                        id: item.id, title: item.title, isDone: item.isDone, sortOrder: item.sortOrder)
                    modelContext.insert(created)
                    created.task = task
                    return created
                }()
            entity.title = item.title
            entity.isDone = item.isDone
            entity.sortOrder = item.sortOrder
        }
    }
}

// MARK: - Release plans

extension SwiftDataRepository: ReleasePlanRepository {
    func plans(projectID: UUID) throws(PersistenceError) -> [ReleasePlan] {
        try projectEntity(projectID).releasePlans.compactMap(ReleasePlan.init).sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ plan: ReleasePlan) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            let project = try projectEntity(plan.projectID)
            let entity: ReleasePlanEntity
            if let existing = try planEntity(plan.id) {
                guard existing.project?.id == plan.projectID else {
                    throw .integrityViolation("A release plan cannot move to another project.")
                }
                entity = existing
            } else {
                entity = ReleasePlanEntity(
                    id: plan.id,
                    version: plan.version,
                    statusRaw: plan.status.rawValue,
                    createdAt: plan.createdAt
                )
                modelContext.insert(entity)
                entity.project = project
            }
            entity.apply(plan)
        }
    }

    func deletePlan(id: UUID) throws(PersistenceError) {
        try transaction { () throws(PersistenceError) in
            guard let entity = try planEntity(id) else { throw .notFound(entity: "release plan", id: id) }
            modelContext.delete(entity)
        }
    }
}
