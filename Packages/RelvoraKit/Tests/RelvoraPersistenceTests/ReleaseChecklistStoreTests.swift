import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension StoreTests {
    @Suite("Release checklists")
    struct ReleaseChecklistStoreTests {
        @Test("Steps are saved in order, edited in place, and deleted with their project")
        func steps() async throws {
            let store = try PersistentStore.inMemory()
            let project = try await ProjectService(repository: store.projects).create(name: "App")
            let service = ReleaseChecklistService(steps: store.releaseSteps, plans: store.releasePlans)
            let saved = try await service.save(
                ["Test on a clean Mac", "Update screenshots", " "].map {
                    ReleaseStep(projectID: project.id, title: $0, sortOrder: 0)
                }, projectID: project.id)
            #expect(try await service.steps(projectID: project.id).map(\.title) == saved.map(\.title))

            var edited = saved.reversed().map(\.self)
            edited[0].title = "Update the screenshots"
            _ = try await service.save(Array(edited.prefix(1)), projectID: project.id)
            let stored = try await service.steps(projectID: project.id)
            #expect(stored.map(\.title) == ["Update the screenshots"] && stored[0].id == saved[1].id)

            try await store.projects.deleteProject(id: project.id)
            await #expect(throws: PersistenceError.self) { try await store.releaseSteps.steps(projectID: project.id) }
        }

        @Test("Ticks are saved on the plan, only while it is planned")
        func ticks() async throws {
            let store = try PersistentStore.inMemory()
            let project = try await ProjectService(repository: store.projects).create(name: "App")
            let service = ReleaseChecklistService(steps: store.releaseSteps, plans: store.releasePlans)
            let step = try #require(
                try await service.save(
                    [ReleaseStep(projectID: project.id, title: "Test on a clean Mac", sortOrder: 1)],
                    projectID: project.id
                ).first)
            let plan = try await ReleasePlanService(repository: store.releasePlans).create(
                projectID: project.id, version: "1.0.0")

            let ticked = try await service.setStep(step.id, done: true, on: plan)
            #expect(try await store.releasePlans.plans(projectID: project.id).first?.completedStepIDs == [step.id])
            #expect(try await service.setStep(step.id, done: false, on: ticked).completedStepIDs.isEmpty)

            let cancelled = try await ReleasePlanService(repository: store.releasePlans).cancel(ticked)
            await #expect(throws: ValidationError.self) {
                try await service.setStep(step.id, done: true, on: cancelled)
            }
        }

        @Test("A V4 store from 0.1.1 migrates to V5 with every record, including groups, intact")
        func v4ToCurrent() async throws {
            let fixture = try #require(
                Bundle.module.url(forResource: "RelvoraV4", withExtension: "store", subdirectory: "Fixtures"))
            let directory = FileManager.default.temporaryDirectory.appending(path: "Migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: "Relvora.store")
            try FileManager.default.copyItem(at: fixture, to: copy)

            let store = try PersistentStore.open(at: copy)
            let migrated = try await BackupService(repository: store.backups).export(appVersion: nil)
            let expectedURL = try #require(
                Bundle.module.url(forResource: "backup-v5", withExtension: "json", subdirectory: "Fixtures"))
            let expected = try BackupService.inspect(try Data(contentsOf: expectedURL)).document
            #expect(migrated.projects == expected.projects)
            #expect(migrated.groups == expected.groups)
            #expect(migrated.projects.allSatisfy { $0.releaseSteps.isEmpty })

            let relvora = try #require(migrated.projects.first { $0.name == "Relvora" })
            _ = try await ReleaseChecklistService(steps: store.releaseSteps, plans: store.releasePlans).save(
                [ReleaseStep(projectID: relvora.id, title: "Test on a clean Mac", sortOrder: 1)], projectID: relvora.id)
            let reopened = try PersistentStore.open(at: copy)
            #expect(
                try await reopened.releaseSteps.steps(projectID: relvora.id).map(\.title) == ["Test on a clean Mac"])
        }
    }
}
