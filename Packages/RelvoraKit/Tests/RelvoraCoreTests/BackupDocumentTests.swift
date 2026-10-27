import Foundation
import Testing

@testable import RelvoraCore

@Suite("Backup document")
struct BackupDocumentTests {
    private func sampleBundle() -> ProjectBundle {
        let project = Project(name: "Relvora", createdAt: Date(timeIntervalSince1970: 1_772_355_600.123))
        let columns = ProjectRules.defaultColumns(projectID: project.id, now: project.createdAt)
        let plan = ReleasePlan(projectID: project.id, version: "1.0.0", plannedDate: project.createdAt)
        let task = ProjectTask(
            projectID: project.id, columnID: columns[0].id, releasePlanID: plan.id, title: "Board",
            labels: ["UI"], checklist: [ChecklistItem(title: "Columns", sortOrder: 1)], sortOrder: 1)
        return ProjectBundle(project: project, columns: columns, tasks: [task], releasePlans: [plan])
    }

    @Test("Encoding and decoding round-trip, with readable dates and enum names")
    func roundTrip() throws {
        let document = BackupDocument(bundles: [sampleBundle()], exportedAt: .now, appVersion: "0.2.0")
        let data = try document.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"formatVersion\" : 6"))
        #expect(text.contains("\"priority\" : \"medium\""))
        #expect(text.contains(".123Z"))

        let decoded = try BackupDocument.decode(data)
        #expect(try decoded.encoded() == data)
        #expect(try decoded.bundles().first?.tasks.first?.labels == ["UI"])
    }

    @Test("Preferences travel in format 4 and older files restore without them")
    func preferences() throws {
        let preferences = BackupDocument.PreferencesRecord(
            appearance: "dark", accentColor: "purple", windowMaterial: "translucent",
            newProjectColumns: [
                ColumnTemplate(name: "Todo", isCompletion: false), ColumnTemplate(name: "Done", isCompletion: true),
            ],
            changelogLabelRules: [ChangelogLabelRule(label: "ui", category: .improvements)],
            githubRefreshInterval: "15m", showsMenuBarIcon: false)
        let document = BackupDocument(bundles: [], exportedAt: .now, appVersion: nil, preferences: preferences)
        let decoded = try BackupDocument.decode(try document.encoded())
        #expect(decoded.preferences == preferences)
        #expect(String(decoding: try document.encoded(), as: UTF8.self).contains("\"category\" : \"improvements\""))

        let old = try BackupDocument.decode(
            Data(#"{"formatVersion": 3, "exportedAt": "2026-03-15T08:00:00Z", "projects": []}"#.utf8))
        #expect(old.preferences == nil)
        // A format 6 file from before the menu bar icon (0.2.3) restores without the switch.
        let formatSix =
            #"{"formatVersion": 6, "exportedAt": "2026-10-26T08:00:00Z", "projects": [], "#
            + #""preferences": {"appearance": "dark"}}"#
        let beforeMenuBar = try BackupDocument.decode(Data(formatSix.utf8))
        #expect(beforeMenuBar.preferences?.showsMenuBarIcon == nil)
        #expect(beforeMenuBar.preferences?.appearance == "dark")

        var broken = document
        broken.preferences?.newProjectColumns = [ColumnTemplate(name: "Only", isCompletion: false)]
        #expect(throws: BackupError.self) { try BackupValidator.validate(broken) }
    }

    @Test("Groups travel in format 5; older files restore with every project outside a group")
    func groups() throws {
        let group = ProjectGroup(name: "Pilou", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_772_355_600))
        var bundle = sampleBundle()
        bundle.project.groupID = group.id
        let document = BackupDocument(bundles: [bundle], groups: [group], exportedAt: .now, appVersion: nil)
        try BackupValidator.validate(document)
        #expect(BackupValidator.summary(of: document).groupCount == 1)

        let decoded = try BackupDocument.decode(try document.encoded())
        #expect(decoded.projectGroups() == [group])
        #expect(try decoded.bundles().first?.project.groupID == group.id)

        let formatFour =
            #"{"formatVersion": 4, "exportedAt": "2026-03-15T08:00:00Z", "projects": [{"id": "\#(UUID())", "#
            + #""name": "App", "createdAt": "2026-03-15T08:00:00Z", "updatedAt": "2026-03-15T08:00:00Z", "#
            + #""columns": [], "tasks": [], "releasePlans": []}]}"#
        let old = try BackupDocument.decode(Data(formatFour.utf8))
        #expect(old.groups == nil && old.projectGroups().isEmpty)
        #expect(old.projects.first?.groupID == nil)

        func broken(_ mutate: (inout BackupDocument) -> Void) -> BackupDocument {
            var copy = document
            mutate(&copy)
            return copy
        }
        let cases = [
            broken { $0.groups = [$0.groups![0], $0.groups![0]] },
            broken {
                var twin = $0.groups![0]
                twin.id = UUID()
                twin.name = "PILOU"
                $0.groups = [$0.groups![0], twin]
            },
            broken { $0.groups?[0].name = " " },
            broken { $0.groups?[0].sortOrder = .nan },
            broken { $0.projects[0].groupID = UUID() },
            broken { $0.groups = nil },
        ]
        for document in cases {
            #expect(throws: BackupError.self) { try BackupValidator.validate(document) }
        }
    }

    @Test("Release checklists and their ticks travel in format 6; older files restore without them")
    func checklists() throws {
        var bundle = sampleBundle()
        let step = ReleaseStep(
            projectID: bundle.project.id, title: "Test on a clean Mac", sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 1_772_355_600))
        bundle.releaseSteps = [step]
        bundle.releasePlans[0].completedStepIDs = [step.id]
        let document = BackupDocument(bundles: [bundle], exportedAt: .now, appVersion: nil)
        try BackupValidator.validate(document)

        let restored = try #require(try BackupDocument.decode(try document.encoded()).bundles().first)
        #expect(restored.releaseSteps == [step])
        #expect(restored.releasePlans.first?.completedStepIDs == [step.id])

        let formatFive =
            #"{"formatVersion": 5, "exportedAt": "2026-03-15T08:00:00Z", "projects": [{"id": "\#(UUID())", "#
            + #""name": "App", "createdAt": "2026-03-15T08:00:00Z", "updatedAt": "2026-03-15T08:00:00Z", "#
            + #""columns": [], "tasks": [], "releasePlans": []}]}"#
        #expect(try BackupDocument.decode(Data(formatFive.utf8)).projects.first?.releaseSteps == [])

        var duplicate = document
        duplicate.projects[0].releaseSteps.append(duplicate.projects[0].releaseSteps[0])
        #expect(throws: BackupError.self) { try BackupValidator.validate(duplicate) }
        var blank = document
        blank.projects[0].releaseSteps[0].title = "  "
        #expect(throws: BackupError.self) { try BackupValidator.validate(blank) }
    }

    @Test("Newer formats and non-backup files are rejected with specific errors")
    func rejection() {
        #expect(throws: BackupError.unsupportedFormatVersion(found: 7, supported: 6)) {
            try BackupDocument.decode(Data(#"{"formatVersion": 7}"#.utf8))
        }
        #expect(throws: BackupError.self) { try BackupDocument.decode(Data("not json".utf8)) }
        #expect(throws: BackupError.self) { try BackupDocument.decode(Data(#"{"formatVersion": 1}"#.utf8)) }
    }

    @Test("Dates without fractional seconds are accepted")
    func plainDates() throws {
        let json = #"{"formatVersion": 1, "exportedAt": "2026-03-15T08:00:00Z", "projects": []}"#
        let document = try BackupDocument.decode(Data(json.utf8))
        #expect(document.exportedAt == Date(timeIntervalSince1970: 1_773_561_600))
    }

    @Test("The validator catches every integrity problem")
    func validation() throws {
        let valid = BackupDocument(bundles: [sampleBundle()], exportedAt: .now, appVersion: nil)
        try BackupValidator.validate(valid)

        func broken(_ mutate: (inout BackupDocument.ProjectRecord) -> Void) -> BackupDocument {
            var copy = valid
            mutate(&copy.projects[0])
            return copy
        }
        let cases: [BackupDocument] = [
            broken {
                $0.columns = $0.columns.map {
                    var c = $0
                    c.isCompletionColumn = false
                    return c
                }
            },
            broken { $0.columns = [] },
            broken { $0.tasks[0].columnID = UUID() },
            broken { $0.tasks[0].releasePlanID = UUID() },
            broken { $0.tasks[0].priority = "critical" },
            broken { $0.tasks[0].title = "  " },
            broken { $0.releasePlans[0].status = "shipped" },
            broken { $0.releasePlans[0].version = "" },
            broken { $0.releasePlans.append($0.releasePlans[0]) },
            broken {
                var second = $0.releasePlans[0]
                second.id = UUID()
                second.version = "2.0.0"
                $0.releasePlans.append(second)
            },
            broken { $0.name = "" },
            {
                var copy = valid
                copy.projects.append(copy.projects[0])
                return copy
            }(),
        ]
        for document in cases {
            #expect(throws: BackupError.self) { try BackupValidator.validate(document) }
        }
    }
}

@Suite("Project service")
struct ProjectServiceTests {
    actor InMemoryProjectRepository: ProjectRepository {
        var stored: [UUID: Project] = [:]
        var columns: [UUID: [BoardColumn]] = [:]
        var failure: PersistenceError?

        func fail(with error: PersistenceError) { failure = error }
        func projects(includeArchived: Bool) -> [Project] { Array(stored.values) }
        func project(id: UUID) throws(PersistenceError) -> Project {
            guard let project = stored[id] else { throw .notFound(entity: "project", id: id) }
            return project
        }
        func create(_ project: Project, columns: [BoardColumn]) throws(PersistenceError) {
            if let failure { throw failure }
            stored[project.id] = project
            self.columns[project.id] = columns
        }
        func update(_ project: Project) throws(PersistenceError) {
            if let failure { throw failure }
            stored[project.id] = project
        }
        func deleteProject(id: UUID) { stored[id] = nil }
    }

    private let fixed = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Creates a trimmed project with its default board")
    func create() async throws {
        let repository = InMemoryProjectRepository()
        let project = try await ProjectService(repository: repository, now: { [fixed] in fixed })
            .create(name: "  Relvora ", details: "   ")
        #expect(project.name == "Relvora")
        #expect(project.details == nil)
        #expect(project.createdAt == fixed)
        #expect(await repository.columns[project.id]?.count == ProjectRules.defaultColumnNames.count)
    }

    @Test("Edits and archiving update timestamps; invalid names never reach the repository")
    func editAndArchive() async throws {
        let repository = InMemoryProjectRepository()
        let service = ProjectService(repository: repository, now: { [fixed] in fixed })
        let original = try await ProjectService(repository: repository).create(name: "Old")

        let renamed = try await service.update(original, name: " New ", details: " Notes ")
        #expect(renamed.name == "New" && renamed.details == "Notes" && renamed.updatedAt == fixed)

        let archived = try await service.setArchived(renamed, true)
        #expect(archived.archivedAt == fixed)
        #expect(try await service.setArchived(archived, false).archivedAt == nil)

        await #expect(throws: ValidationError.emptyName) { try await service.update(renamed, name: " ", details: nil) }
        #expect(await repository.stored[original.id]?.name == "New")
    }

    @Test("New projects use the board template from Settings; bad templates are refused")
    func boardTemplate() async throws {
        let repository = InMemoryProjectRepository()
        let template = [
            ColumnTemplate(name: " Ideas ", isCompletion: false), ColumnTemplate(name: "Shipped", isCompletion: true),
        ]
        let project = try await ProjectService(repository: repository).create(name: "App", columns: template)
        let columns = try #require(await repository.columns[project.id])
        #expect(columns.map(\.name) == ["Ideas", "Shipped"])
        #expect(columns.map(\.isCompletionColumn) == [false, true])

        #expect(throws: ValidationError.needsOneCompletionColumn) {
            try ProjectRules.validatedTemplate([ColumnTemplate(name: "A", isCompletion: false)])
        }
        #expect(throws: ValidationError.duplicateColumnName("done")) {
            try ProjectRules.validatedTemplate([
                ColumnTemplate(name: "Done", isCompletion: true), ColumnTemplate(name: "done", isCompletion: false),
            ])
        }
        #expect(throws: ValidationError.cannotDeleteLastColumn) { try ProjectRules.validatedTemplate([]) }
        await #expect(throws: ValidationError.self) {
            try await ProjectService(repository: repository).create(name: "Bad", columns: [])
        }
    }

    @Test("Projects are created in a group and move between groups")
    func groups() async throws {
        let repository = InMemoryProjectRepository()
        let service = ProjectService(repository: repository, now: { [fixed] in fixed })
        let pilou = UUID()
        let project = try await service.create(name: "Pilou Web", groupID: pilou)
        #expect(await repository.stored[project.id]?.groupID == pilou)

        let moved = try await service.setGroup(project, nil)
        #expect(moved.groupID == nil && moved.updatedAt == fixed)
        #expect(await repository.stored[project.id]?.groupID == nil)

        var edited = moved
        edited.groupID = pilou
        #expect(try await service.update(edited, name: "Web", details: nil).groupID == pilou)
    }

    @Test("Persistence failures propagate unchanged")
    func failure() async {
        let repository = InMemoryProjectRepository()
        await repository.fail(with: .saveFailed(reason: "disk full"))
        await #expect(throws: PersistenceError.saveFailed(reason: "disk full")) {
            try await ProjectService(repository: repository).create(name: "Relvora")
        }
    }
}
