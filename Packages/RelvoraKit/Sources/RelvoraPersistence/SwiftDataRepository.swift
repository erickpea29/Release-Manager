import Foundation
import RelvoraCore
import SwiftData

/// SwiftData implementation of every repository protocol.
///
/// Each public method runs in its own fresh `ModelContext`. A write saves once at the end; if anything
/// fails first, the context is discarded. M02 found that `ModelContext.rollback()` did not undo property
/// changes on already-fetched objects, so a shared context could carry a rejected edit into a later save.
/// The actor serializes writers.
actor SwiftDataRepository {
    private let container: ModelContainer

    init(modelContainer: ModelContainer) {
        self.container = modelContainer
    }

    // MARK: - Context helpers

    private func read<Result>(_ body: (ModelContext) throws(PersistenceError) -> Result) throws(PersistenceError)
        -> Result
    {
        try body(ModelContext(container))
    }

    private func transaction(_ body: (ModelContext) throws(PersistenceError) -> Void) throws(PersistenceError) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try body(context)
        do {
            try context.save()
        } catch {
            Log.persistence.error("Save failed: \(String(describing: error), privacy: .private)")
            throw .saveFailed(reason: String(describing: error))
        }
    }

    private func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>, in context: ModelContext)
        throws(PersistenceError) -> [Model]
    {
        do {
            return try context.fetch(descriptor)
        } catch {
            Log.persistence.error("Fetch failed: \(String(describing: error), privacy: .private)")
            throw .fetchFailed(reason: String(describing: error))
        }
    }

    private func projectEntity(_ id: UUID, in context: ModelContext) throws(PersistenceError) -> ProjectEntity {
        var descriptor = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let entity = try fetch(descriptor, in: context).first else { throw .notFound(entity: "project", id: id) }
        return entity
    }

    private func columnEntity(_ id: UUID, in context: ModelContext) throws(PersistenceError) -> BoardColumnEntity? {
        var descriptor = FetchDescriptor<BoardColumnEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor, in: context).first
    }

    private func taskEntity(_ id: UUID, in context: ModelContext) throws(PersistenceError) -> TaskEntity? {
        var descriptor = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor, in: context).first
    }

    private func planEntity(_ id: UUID, in context: ModelContext) throws(PersistenceError) -> ReleasePlanEntity? {
        var descriptor = FetchDescriptor<ReleasePlanEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor, in: context).first
    }

    @discardableResult
    private func insertProject(_ project: Project, in context: ModelContext) -> ProjectEntity {
        let entity = ProjectEntity(id: project.id, name: project.name, createdAt: project.createdAt)
        entity.apply(project)
        context.insert(entity)
        return entity
    }

    @discardableResult
    private func insertColumn(_ column: BoardColumn, into project: ProjectEntity, in context: ModelContext)
        -> BoardColumnEntity
    {
        let entity = BoardColumnEntity(
            id: column.id,
            name: column.name,
            sortOrder: column.sortOrder,
            isCompletionColumn: column.isCompletionColumn,
            createdAt: column.createdAt
        )
        entity.updatedAt = column.updatedAt
        context.insert(entity)
        entity.project = project
        return entity
    }

    @discardableResult
    private func insertPlan(_ plan: ReleasePlan, into project: ProjectEntity, in context: ModelContext)
        -> ReleasePlanEntity
    {
        let entity = ReleasePlanEntity(
            id: plan.id, version: plan.version, statusRaw: plan.status.rawValue, createdAt: plan.createdAt)
        context.insert(entity)
        entity.project = project
        entity.apply(plan)
        return entity
    }

    @discardableResult
    private func insertConnection(
        _ connection: RepositoryConnection, into project: ProjectEntity, in context: ModelContext
    ) -> RepositoryConnectionEntity {
        let entity = RepositoryConnectionEntity(
            id: connection.id,
            githubRepositoryID: connection.githubRepositoryID,
            owner: connection.owner,
            name: connection.name,
            htmlURL: connection.htmlURL.absoluteString,
            createdAt: connection.createdAt
        )
        context.insert(entity)
        entity.project = project
        entity.apply(connection)
        return entity
    }

    private func insertSnapshot(_ snapshot: ReleaseSnapshot, into project: ProjectEntity, in context: ModelContext) {
        let entity = ReleaseSnapshotEntity(snapshot)
        context.insert(entity)
        entity.project = project
    }

    private func snapshotEntity(_ id: UUID, in context: ModelContext) throws(PersistenceError)
        -> ReleaseSnapshotEntity?
    {
        var descriptor = FetchDescriptor<ReleaseSnapshotEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try fetch(descriptor, in: context).first
    }

    private func insertTask(
        _ task: ProjectTask,
        project: ProjectEntity,
        column: BoardColumnEntity,
        plan: ReleasePlanEntity?,
        in context: ModelContext
    ) {
        let entity = TaskEntity(
            id: task.id,
            title: task.title,
            priorityRaw: task.priority.rawValue,
            typeRaw: task.type.rawValue,
            sortOrder: task.sortOrder,
            createdAt: task.createdAt
        )
        context.insert(entity)
        entity.project = project
        entity.apply(task)
        entity.column = column
        entity.releasePlan = plan
        syncChecklist(of: entity, to: task.checklist, in: context)
    }

    private func syncChecklist(of task: TaskEntity, to items: [ChecklistItem], in context: ModelContext) {
        let wanted = Set(items.map(\.id))
        for stale in task.checklist where !wanted.contains(stale.id) {
            context.delete(stale)
        }
        let existing = Dictionary(
            task.checklist.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in items {
            let entity =
                existing[item.id]
                ?? {
                    let created = ChecklistItemEntity(
                        id: item.id, title: item.title, isDone: item.isDone, sortOrder: item.sortOrder)
                    context.insert(created)
                    created.task = task
                    return created
                }()
            entity.title = item.title
            entity.isDone = item.isDone
            entity.sortOrder = item.sortOrder
        }
    }
}

// MARK: - Projects

extension SwiftDataRepository: ProjectRepository {
    func projects(includeArchived: Bool) throws(PersistenceError) -> [Project] {
        try read { context throws(PersistenceError) in
            try fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.createdAt)]), in: context)
                .filter { includeArchived || $0.archivedAt == nil }
                .map(Project.init)
        }
    }

    func project(id: UUID) throws(PersistenceError) -> Project {
        try read { context throws(PersistenceError) in Project(try projectEntity(id, in: context)) }
    }

    func create(_ project: Project, columns: [BoardColumn]) throws(PersistenceError) {
        guard columns.allSatisfy({ $0.projectID == project.id }) else {
            throw .integrityViolation("Columns must belong to the project being created.")
        }
        guard columns.filter(\.isCompletionColumn).count == 1 else {
            throw .integrityViolation("A project needs exactly one completion column.")
        }
        try transaction { context throws(PersistenceError) in
            let entity = insertProject(project, in: context)
            for column in columns {
                insertColumn(column, into: entity, in: context)
            }
        }
    }

    func update(_ project: Project) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            try projectEntity(project.id, in: context).apply(project)
        }
    }

    func deleteProject(id: UUID) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            context.delete(try projectEntity(id, in: context))
        }
    }
}

// MARK: - Board

extension SwiftDataRepository: BoardRepository {
    func columns(projectID: UUID) throws(PersistenceError) -> [BoardColumn] {
        try read { context throws(PersistenceError) in
            try projectEntity(projectID, in: context).columns.map(BoardColumn.init).sorted {
                $0.sortOrder < $1.sortOrder
            }
        }
    }

    func tasks(projectID: UUID) throws(PersistenceError) -> [ProjectTask] {
        try read { context throws(PersistenceError) in
            try projectEntity(projectID, in: context).tasks.compactMap(ProjectTask.init)
                .sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    func apply(_ changes: BoardChanges) throws(PersistenceError) {
        guard !changes.isEmpty else { return }
        try transaction { context throws(PersistenceError) in
            // Column membership and completion flags as they will be after this batch. Tracked here instead of
            // read back from relationships, so the checks don't depend on when inverse relationships update.
            var columnProject: [UUID: UUID] = [:]
            var completion: [UUID: [UUID: Bool]] = [:]
            func track(_ entity: BoardColumnEntity, projectID: UUID) {
                columnProject[entity.id] = projectID
                completion[projectID, default: [:]][entity.id] = entity.isCompletionColumn
            }
            func trackAll(of project: ProjectEntity) {
                for existing in project.columns where completion[project.id]?[existing.id] == nil {
                    track(existing, projectID: project.id)
                }
            }

            for column in changes.upsertColumns {
                let project = try projectEntity(column.projectID, in: context)
                trackAll(of: project)
                let entity: BoardColumnEntity
                if let existing = try columnEntity(column.id, in: context) {
                    guard existing.project?.id == column.projectID else {
                        throw .integrityViolation("A column cannot move to another project.")
                    }
                    entity = existing
                } else {
                    entity = insertColumn(column, into: project, in: context)
                }
                entity.name = column.name
                entity.sortOrder = column.sortOrder
                entity.isCompletionColumn = column.isCompletionColumn
                entity.updatedAt = column.updatedAt
                track(entity, projectID: project.id)
            }

            for task in changes.upsertTasks {
                try upsert(task, columnProject: columnProject, in: context)
            }

            for id in changes.deleteTaskIDs {
                guard let entity = try taskEntity(id, in: context) else { throw .notFound(entity: "task", id: id) }
                context.delete(entity)
            }

            let deletedTasks = Set(changes.deleteTaskIDs)
            let taskColumns = Dictionary(changes.upsertTasks.map { ($0.id, $0.columnID) }, uniquingKeysWith: { $1 })
            for id in changes.deleteColumnIDs {
                guard let entity = try columnEntity(id, in: context), let project = entity.project else {
                    throw .notFound(entity: "column", id: id)
                }
                trackAll(of: project)
                let remaining = entity.tasks.filter { task in
                    !deletedTasks.contains(task.id) && (taskColumns[task.id] ?? id) == id
                }
                let arriving = changes.upsertTasks.contains { $0.columnID == id }
                guard remaining.isEmpty, !arriving else {
                    throw .integrityViolation("A column must be empty before it is deleted.")
                }
                completion[project.id]?[id] = nil
                context.delete(entity)
            }

            for (_, columns) in completion {
                guard !columns.isEmpty, columns.values.filter({ $0 }).count == 1 else {
                    throw .integrityViolation("A project needs at least one column and exactly one completion column.")
                }
            }
        }
    }

    private func upsert(_ task: ProjectTask, columnProject: [UUID: UUID], in context: ModelContext)
        throws(PersistenceError)
    {
        let project = try projectEntity(task.projectID, in: context)
        guard let column = try columnEntity(task.columnID, in: context),
            (columnProject[task.columnID] ?? column.project?.id) == task.projectID
        else {
            throw .integrityViolation("A task's column must belong to the task's project.")
        }
        var plan: ReleasePlanEntity?
        if let planID = task.releasePlanID {
            guard let found = try planEntity(planID, in: context), found.project?.id == task.projectID else {
                throw .integrityViolation("A task's release plan must belong to the task's project.")
            }
            plan = found
        }

        guard let existing = try taskEntity(task.id, in: context) else {
            insertTask(task, project: project, column: column, plan: plan, in: context)
            return
        }
        guard existing.project?.id == task.projectID else {
            throw .integrityViolation("A task cannot move to another project.")
        }
        existing.apply(task)
        existing.column = column
        existing.releasePlan = plan
        syncChecklist(of: existing, to: task.checklist, in: context)
    }
}

// MARK: - Release plans

extension SwiftDataRepository: ReleasePlanRepository {
    func plans(projectID: UUID) throws(PersistenceError) -> [ReleasePlan] {
        try read { context throws(PersistenceError) in
            try projectEntity(projectID, in: context).releasePlans.compactMap(ReleasePlan.init)
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    func save(_ plan: ReleasePlan) throws(PersistenceError) {
        guard plan.status == .planned || plan.status == .cancelled else {
            throw .integrityViolation("Release states after planning are recorded by the release workflow.")
        }
        try transaction { context throws(PersistenceError) in
            let project = try projectEntity(plan.projectID, in: context)
            if let existing = try planEntity(plan.id, in: context) {
                guard existing.project?.id == plan.projectID else {
                    throw .integrityViolation("A release plan cannot move to another project.")
                }
                // Later states belong to the release workflow (`record`); an edit must never overwrite them.
                guard existing.statusRaw == ReleasePlanStatus.planned.rawValue else {
                    throw .outdated(entity: "release plan")
                }
                existing.apply(plan)
            } else {
                insertPlan(plan, into: project, in: context)
            }
        }
    }

    func deletePlan(id: UUID) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            guard let entity = try planEntity(id, in: context) else {
                throw .notFound(entity: "release plan", id: id)
            }
            let status = ReleasePlanStatus(rawValue: entity.statusRaw)
            guard status == .planned || status == .cancelled else { throw .outdated(entity: "release plan") }
            context.delete(entity)
        }
    }
}

// MARK: - Backup

extension SwiftDataRepository: BackupRepository {
    func allProjectBundles() throws(PersistenceError) -> [ProjectBundle] {
        try read { context throws(PersistenceError) in
            try fetch(FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.createdAt)]), in: context).map {
                entity in
                ProjectBundle(
                    project: Project(entity),
                    columns: entity.columns.map(BoardColumn.init).sorted { $0.sortOrder < $1.sortOrder },
                    tasks: entity.tasks.compactMap(ProjectTask.init).sorted { $0.sortOrder < $1.sortOrder },
                    releasePlans: entity.releasePlans.compactMap(ReleasePlan.init).sorted {
                        $0.createdAt < $1.createdAt
                    },
                    repositoryConnections: entity.repositoryConnections.compactMap(RepositoryConnection.init).sorted {
                        $0.createdAt < $1.createdAt
                    },
                    releaseSnapshots: entity.releaseSnapshots.compactMap(ReleaseSnapshot.init).sorted {
                        $0.snapshotCreatedAt < $1.snapshotCreatedAt
                    }
                )
            }
        }
    }

    func replaceAll(with bundles: [ProjectBundle]) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            for project in try fetch(FetchDescriptor<ProjectEntity>(), in: context) {
                context.delete(project)
            }
            for bundle in bundles {
                let project = insertProject(bundle.project, in: context)
                var columns: [UUID: BoardColumnEntity] = [:]
                for column in bundle.columns {
                    columns[column.id] = insertColumn(column, into: project, in: context)
                }
                var plans: [UUID: ReleasePlanEntity] = [:]
                for plan in bundle.releasePlans {
                    plans[plan.id] = insertPlan(plan, into: project, in: context)
                }
                for connection in bundle.repositoryConnections {
                    insertConnection(connection, into: project, in: context)
                }
                for snapshot in bundle.releaseSnapshots {
                    insertSnapshot(snapshot, into: project, in: context)
                }
                for task in bundle.tasks {
                    guard let column = columns[task.columnID] else {
                        throw .integrityViolation("A task references a missing column.")
                    }
                    insertTask(
                        task, project: project, column: column, plan: task.releasePlanID.flatMap { plans[$0] },
                        in: context)
                }
            }
        }
    }
}

// MARK: - Repository connections

extension SwiftDataRepository: RepositoryConnectionRepository {
    func connections(projectID: UUID) throws(PersistenceError) -> [RepositoryConnection] {
        try read { context throws(PersistenceError) in
            try projectEntity(projectID, in: context).repositoryConnections.compactMap(RepositoryConnection.init)
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    func save(_ connection: RepositoryConnection) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            let project = try projectEntity(connection.projectID, in: context)
            let duplicate = project.repositoryConnections.contains {
                $0.githubRepositoryID == connection.githubRepositoryID && $0.id != connection.id
            }
            guard !duplicate else {
                throw .integrityViolation("A project can connect a GitHub repository only once.")
            }
            if let existing = project.repositoryConnections.first(where: { $0.id == connection.id }) {
                guard existing.githubRepositoryID == connection.githubRepositoryID else {
                    throw .integrityViolation("A connection cannot change its GitHub repository.")
                }
                existing.apply(connection)
            } else {
                let connectionID = connection.id
                var descriptor = FetchDescriptor<RepositoryConnectionEntity>(
                    predicate: #Predicate { $0.id == connectionID })
                descriptor.fetchLimit = 1
                guard try fetch(descriptor, in: context).isEmpty else {
                    throw .integrityViolation("A connection cannot move to another project.")
                }
                insertConnection(connection, into: project, in: context)
            }
        }
    }

    func deleteConnection(id: UUID) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            var descriptor = FetchDescriptor<RepositoryConnectionEntity>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let entity = try fetch(descriptor, in: context).first else {
                throw .notFound(entity: "repository connection", id: id)
            }
            context.delete(entity)
        }
    }
}

// MARK: - Release snapshots

extension SwiftDataRepository: ReleaseSnapshotRepository {
    func snapshots(projectID: UUID) throws(PersistenceError) -> [ReleaseSnapshot] {
        try read { context throws(PersistenceError) in
            try projectEntity(projectID, in: context).releaseSnapshots.compactMap(ReleaseSnapshot.init)
                .sorted { $0.snapshotCreatedAt < $1.snapshotCreatedAt }
        }
    }

    func allSnapshots() throws(PersistenceError) -> [ReleaseSnapshot] {
        try read { context throws(PersistenceError) in
            try fetch(
                FetchDescriptor<ReleaseSnapshotEntity>(sortBy: [SortDescriptor(\.snapshotCreatedAt)]), in: context
            )
            .compactMap(ReleaseSnapshot.init)
        }
    }

    func record(_ record: ReleaseRecord) throws(PersistenceError) {
        try transaction { context throws(PersistenceError) in
            guard let plan = try planEntity(record.planID, in: context), let project = plan.project else {
                throw .notFound(entity: "release plan", id: record.planID)
            }
            // Compare-and-set: a second attempt that read the same state fails here instead of acting twice.
            guard plan.statusRaw == record.expectedStatus.rawValue else { throw .outdated(entity: "release plan") }

            switch record.operation {
            case .none:
                break
            case .insert(let snapshot):
                guard snapshot.projectID == project.id, snapshot.releasePlanID == plan.id else {
                    throw .integrityViolation("A release snapshot must belong to its plan's project.")
                }
                switch (snapshot.origin, snapshot.state) {
                case (.relvoraDraft, .pending), (.external, .published): break
                default:
                    throw .integrityViolation("A new release snapshot starts as pending, or published from GitHub.")
                }
                guard try snapshotEntity(snapshot.id, in: context) == nil else {
                    throw .integrityViolation("A release snapshot can only be created once.")
                }
                let hasOpen = project.releaseSnapshots.contains {
                    $0.releasePlanID == plan.id && ReleaseSnapshotState(rawValue: $0.stateRaw)?.isOpen == true
                }
                guard !hasOpen else { throw .outdated(entity: "release plan") }
                insertSnapshot(snapshot, into: project, in: context)
            case .transition(let id, let transition):
                guard let entity = try snapshotEntity(id, in: context), entity.project?.id == project.id,
                    entity.releasePlanID == plan.id, let current = ReleaseSnapshot(entity)
                else { throw .notFound(entity: "release snapshot", id: id) }
                guard let next = current.applying(transition, at: record.date) else {
                    throw .integrityViolation("Release snapshots can't change that way.")
                }
                entity.applyLifecycle(next)
            case .discardPending(let id):
                guard let entity = try snapshotEntity(id, in: context), entity.project?.id == project.id,
                    entity.releasePlanID == plan.id
                else { throw .notFound(entity: "release snapshot", id: id) }
                guard entity.stateRaw == ReleaseSnapshotState.pending.rawValue else {
                    throw .integrityViolation("Only an unconfirmed release snapshot can be discarded.")
                }
                context.delete(entity)
            }

            plan.statusRaw = record.newStatus.rawValue
            if let releasedAt = record.releasedAt { plan.releasedAt = releasedAt }
            if let sha = record.targetCommitSHA { plan.targetCommitSHA = sha }
            plan.updatedAt = record.date
        }
    }
}
