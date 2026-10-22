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
