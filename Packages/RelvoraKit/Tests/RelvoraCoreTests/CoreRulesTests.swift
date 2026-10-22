import Foundation
import Testing

@testable import RelvoraCore

@Suite("Fractional ordering")
struct FractionalIndexTests {
    @Test("Keys order between neighbours, before the first, and after the last")
    func between() {
        #expect(FractionalIndex.between(nil, nil) == 1)
        #expect(FractionalIndex.between(3, nil) == 4)
        #expect(FractionalIndex.between(nil, 1) == 0)
        let middle = FractionalIndex.between(1, 2)
        #expect(1 < middle && middle < 2)
    }

    @Test("Repeated insertion eventually requires renormalization")
    func exhaustion() {
        var upper = 2.0
        var insertions = 0
        while !FractionalIndex.needsRenormalization(1, upper) {
            upper = FractionalIndex.between(1, upper)
            insertions += 1
        }
        #expect(insertions > 20)
        #expect(FractionalIndex.renormalized(count: 4) == [1, 2, 3, 4])
        #expect(FractionalIndex.renormalized(count: 0).isEmpty)
    }
}

@Suite("Task labels")
struct LabelTests {
    @Test("Labels are trimmed, de-duplicated case-insensitively, and empty ones dropped")
    func normalization() {
        #expect(ProjectTask.normalizedLabels([" UI ", "ui", "", "Backend", "  ", "backend"]) == ["UI", "Backend"])
    }
}

@Suite("Project rules")
struct ProjectRulesTests {
    @Test("Names are trimmed and validated")
    func names() throws {
        #expect(try ProjectRules.validatedName("  Relvora  ") == "Relvora")
        #expect(throws: ValidationError.emptyName) { try ProjectRules.validatedName(" \n ") }
        let tooLong = String(repeating: "a", count: ProjectRules.maximumNameLength + 1)
        #expect(throws: ValidationError.nameTooLong(maximum: ProjectRules.maximumNameLength)) {
            try ProjectRules.validatedName(tooLong)
        }
    }

    @Test("The default board has five ordered columns and one completion column at the end")
    func defaultBoard() {
        let projectID = UUID()
        let columns = ProjectRules.defaultColumns(projectID: projectID, now: .now)
        #expect(columns.map(\.name) == ["Backlog", "To Do", "In Progress", "Review", "Done"])
        #expect(columns.map(\.sortOrder) == columns.map(\.sortOrder).sorted())
        #expect(columns.filter(\.isCompletionColumn).map(\.name) == ["Done"])
        #expect(columns.allSatisfy { $0.projectID == projectID })
    }

    @Test("Every error has a user-facing message and a suggestion")
    func errorMessages() {
        let errors: [any LocalizedError] = [
            ValidationError.emptyName, ValidationError.nameTooLong(maximum: 1), ValidationError.invalidVersion("x"),
            PersistenceError.storeUnavailable(reason: "r"), PersistenceError.notFound(entity: "project", id: UUID()),
            PersistenceError.integrityViolation("r"), PersistenceError.fetchFailed(reason: "r"),
            PersistenceError.saveFailed(reason: "r"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
        // Technical detail never reaches the user-facing text.
        #expect(PersistenceError.saveFailed(reason: "SQLITE_FULL").errorDescription?.contains("SQLITE") == false)
    }
}

@Suite("Create project use case")
struct CreateProjectTests {
    actor InMemoryProjectRepository: ProjectRepository {
        var created: [(Project, [BoardColumn])] = []
        var failure: PersistenceError?

        func fail(with error: PersistenceError) { failure = error }
        func projects(includeArchived: Bool) -> [Project] { created.map(\.0) }
        func project(id: UUID) throws(PersistenceError) -> Project {
            guard let project = created.first(where: { $0.0.id == id })?.0 else {
                throw .notFound(entity: "project", id: id)
            }
            return project
        }
        func create(_ project: Project, columns: [BoardColumn]) throws(PersistenceError) {
            if let failure { throw failure }
            created.append((project, columns))
        }
        func update(_ project: Project) {}
        func deleteProject(id: UUID) {}
    }

    @Test("Creates a trimmed project with its default board in one call")
    func creates() async throws {
        let repository = InMemoryProjectRepository()
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let create = CreateProject(repository: repository, now: { fixed })

        let project = try await create(name: "  Relvora ", details: "   ")

        #expect(project.name == "Relvora")
        #expect(project.details == nil)
        #expect(project.createdAt == fixed && project.updatedAt == fixed)
        let stored = await repository.created
        #expect(stored.count == 1)
        #expect(stored.first?.1.count == ProjectRules.defaultColumnNames.count)
        #expect(stored.first?.1.allSatisfy { $0.projectID == project.id } == true)
    }

    @Test("Invalid names never reach the repository")
    func validation() async {
        let repository = InMemoryProjectRepository()
        await #expect(throws: ValidationError.emptyName) { try await CreateProject(repository: repository)(name: "") }
        #expect(await repository.created.isEmpty)
    }

    @Test("Persistence failures propagate unchanged")
    func persistenceFailure() async {
        let repository = InMemoryProjectRepository()
        await repository.fail(with: .saveFailed(reason: "disk full"))
        await #expect(throws: PersistenceError.saveFailed(reason: "disk full")) {
            try await CreateProject(repository: repository)(name: "Relvora")
        }
    }
}
