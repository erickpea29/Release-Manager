import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

let targetSHA = String(repeating: "a", count: 40)
let otherSHA = String(repeating: "b", count: 40)
private let repositoryURL = URL(string: "https://github.com/octo/app")!
private let githubRepository = GitHubRepository(
    id: 42, owner: "octo", name: "app", defaultBranch: "main", htmlURL: repositoryURL, isPrivate: true)

struct FakeGitHubError: Error, Equatable {
    let message: String
}

/// GitHub's release behavior in memory, including what M00 found live: drafts don't create their tag, and
/// duplicate drafts for one tag are accepted.
actor FakeReleaseRemote: ReleaseRemote {
    enum CreateBehavior {
        case succeed
        case reject
        /// GitHub creates the draft but the response is lost.
        case timeoutAfterCreating
        case timeoutWithoutCreating
    }

    var createBehavior = CreateBehavior.succeed
    private(set) var createRequests: [DraftReleaseRequest] = []
    private(set) var releases: [RemoteRelease] = []
    private var tags: [String: String] = [:]
    private var nextID: Int64 = 100
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    func setCreateBehavior(_ behavior: CreateBehavior) { createBehavior = behavior }
    func setTag(_ name: String, at sha: String) { tags[name] = sha }

    @discardableResult
    func addRelease(tag: String, target: String, draft: Bool, body: String? = nil) -> RemoteRelease {
        clock += 60
        nextID += 1
        let release = RemoteRelease(
            id: nextID, tagName: tag, name: tag, isDraft: draft, isPrerelease: false, createdAt: clock,
            publishedAt: draft ? nil : clock, targetCommitish: target,
            htmlURL: repositoryURL.appending(path: draft ? "releases/tag/untagged-\(nextID)" : "releases/tag/\(tag)"),
            body: body)
        releases.append(release)
        if !draft && tags[tag] == nil { tags[tag] = target }
        return release
    }

    /// Publishing on GitHub creates the tag at the target commit, unless the tag already exists.
    func publish(_ id: Int64, body: String? = nil, as tag: String? = nil) {
        guard let index = releases.firstIndex(where: { $0.id == id }) else { return }
        let draft = releases[index]
        let tagName = tag ?? draft.tagName
        clock += 60
        releases[index] = RemoteRelease(
            id: draft.id, tagName: tagName, name: draft.name, isDraft: false, isPrerelease: draft.isPrerelease,
            createdAt: draft.createdAt, publishedAt: clock, targetCommitish: draft.targetCommitish,
            htmlURL: repositoryURL.appending(path: "releases/tag/\(tagName)"), body: body ?? draft.body)
        if tags[tagName] == nil { tags[tagName] = draft.targetCommitish }
    }

    func delete(_ id: Int64) { releases.removeAll { $0.id == id } }

    // MARK: ReleaseRemote

    func repository(id: Int64) async throws -> GitHubRepository {
        guard id == githubRepository.id else { throw FakeGitHubError(message: "Not Found") }
        return githubRepository
    }

    func releases(of repository: GitHubRepository) async throws -> (items: [RemoteRelease], truncated: Bool) {
        (releases.sorted { $0.createdAt > $1.createdAt }, false)
    }

    func release(of repository: GitHubRepository, id: Int64) async throws -> RemoteRelease? {
        releases.first { $0.id == id }
    }

    func tagCommitSHA(of repository: GitHubRepository, tag: String) async throws -> String? { tags[tag] }

    func createDraftRelease(in repository: GitHubRepository, _ request: DraftReleaseRequest) async
        -> DraftCreationResult
    {
        createRequests.append(request)
        switch createBehavior {
        case .succeed:
            return .created(
                addRelease(tag: request.tagName, target: request.targetCommitSHA, draft: true, body: request.body))
        case .reject:
            return .rejected(FakeGitHubError(message: "Validation Failed"))
        case .timeoutAfterCreating:
            addRelease(tag: request.tagName, target: request.targetCommitSHA, draft: true, body: request.body)
            return .unknown(FakeGitHubError(message: "Timed out"))
        case .timeoutWithoutCreating:
            return .unknown(FakeGitHubError(message: "Timed out"))
        }
    }
}

/// Fails the save that records a confirmed draft, once.
final class FlakySnapshotRepository: ReleaseSnapshotRepository, @unchecked Sendable {
    private let base: any ReleaseSnapshotRepository
    private let lock = NSLock()
    private var shouldFail = true

    init(_ base: any ReleaseSnapshotRepository) { self.base = base }

    func snapshots(projectID: UUID) async throws(PersistenceError) -> [ReleaseSnapshot] {
        try await base.snapshots(projectID: projectID)
    }

    func allSnapshots() async throws(PersistenceError) -> [ReleaseSnapshot] { try await base.allSnapshots() }

    func record(_ record: ReleaseRecord) async throws(PersistenceError) {
        if case .transition(_, .draftConfirmed) = record.operation,
            lock.withLock({
                defer { shouldFail = false }
                return shouldFail
            })
        {
            throw .saveFailed(reason: "Simulated disk failure")
        }
        try await base.record(record)
    }
}

func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}

/// A project with a connected repository, a ready plan, one done task, and optionally open tasks.
struct WorkflowFixture {
    let store: PersistentStore
    let remote = FakeReleaseRemote()
    let workflow: ReleaseWorkflow
    let project: Project
    let connection: RepositoryConnection
    let plan: ReleasePlan
    let doneTask: ProjectTask

    init(openTasks: Int = 0, flakySave: Bool = false) async throws {
        store = try PersistentStore.inMemory()
        project = try await ProjectService(repository: store.projects).create(name: "App")
        connection = try await RepositoryConnectionService(repository: store.repositoryConnections).connect(
            githubRepository, to: project.id)
        let plans = ReleasePlanService(repository: store.releasePlans)
        var plan = try await plans.create(projectID: project.id, version: "1.1.0", title: "Login")
        plan.repositoryConnectionID = connection.id
        plan.targetBranch = "main"
        plan.targetCommitSHA = targetSHA
        plan.tagName = "v1.1.0"
        plan.changelogMarkdown = "## Features\n\n- Login (#5)\n"
        self.plan = try await plans.update(plan)

        let board = BoardService(repository: store.board)
        let columns = try await store.board.columns(projectID: project.id)
        let done = try #require(columns.first { $0.isCompletionColumn })
        let state = try await board.createTask(
            ProjectTask(
                projectID: project.id, columnID: done.id, releasePlanID: plan.id, title: "Login screen",
                details: "Email and password", type: .feature, labels: ["Auth"], sortOrder: 0))
        doneTask = try #require(state.tasks.first)
        for index in 0..<openTasks {
            _ = try await board.createTask(
                ProjectTask(
                    projectID: project.id, columnID: columns[0].id, releasePlanID: plan.id, title: "Open \(index)",
                    sortOrder: 0))
        }

        let snapshots: any ReleaseSnapshotRepository =
            flakySave ? FlakySnapshotRepository(store.releaseSnapshots) : store.releaseSnapshots
        workflow = ReleaseWorkflow(
            plans: store.releasePlans, snapshots: snapshots, board: store.board,
            connections: store.repositoryConnections, remote: remote)
    }

    var review: ReleaseReview { ReleaseReview(plan: plan, connection: connection, changes: nil)! }

    func currentPlan() async throws -> ReleasePlan {
        try #require(try await store.releasePlans.plans(projectID: project.id).first { $0.id == plan.id })
    }

    func snapshots() async throws -> [ReleaseSnapshot] {
        try await store.releaseSnapshots.snapshots(projectID: project.id)
    }
}

extension StoreTests {
    @Suite("Release workflow")
    struct ReleaseWorkflowTests {
        @Test("Creates a draft with the reviewed tag, commit, and notes, and freezes the tasks")
        func createDraft() async throws {
            let fixture = try await WorkflowFixture()
            let snapshot = try await fixture.workflow.createDraft(fixture.review)

            let request = try #require(await fixture.remote.createRequests.first)
            #expect(
                request
                    == DraftReleaseRequest(
                        tagName: "v1.1.0", targetCommitSHA: targetSHA, name: "1.1.0 – Login",
                        body: "## Features\n\n- Login (#5)\n", isPrerelease: false))
            #expect(snapshot.state == .draftCreated && snapshot.githubReleaseID != nil)
            #expect(snapshot.tasks.map(\.title) == ["Login screen"])
            #expect(snapshot.tasks.first?.columnName == "Done" && snapshot.tasks.first?.isCompleted == true)
            #expect(try await fixture.currentPlan().status == .draftCreated)
            #expect(try await fixture.snapshots() == [snapshot])
            // Drafts never create tags; publication is not claimed.
            #expect(try await fixture.remote.tagCommitSHA(of: githubRepository, tag: "v1.1.0") == nil)
        }

        @Test("Snapshots don't change when their source tasks are edited or deleted")
        func immutability() async throws {
            let fixture = try await WorkflowFixture()
            let snapshot = try await fixture.workflow.createDraft(fixture.review)

            let board = BoardService(repository: fixture.store.board)
            var edited = fixture.doneTask
            edited.title = "Renamed"
            edited.labels = []
            _ = try await board.updateTask(edited)
            #expect(try await fixture.snapshots().first?.tasks == snapshot.tasks)
            _ = try await board.deleteTask(fixture.doneTask.id, projectID: fixture.project.id)
            #expect(try await fixture.snapshots().first == snapshot)
            #expect(snapshot.tasks.first?.title == "Login screen" && snapshot.tasks.first?.labels == ["Auth"])
        }

        @Test("Duplicate requests send a single create")
        func duplicateRequests() async throws {
            let fixture = try await WorkflowFixture()
            async let first = attempt { try await fixture.workflow.createDraft(fixture.review) }
            async let second = attempt { try await fixture.workflow.createDraft(fixture.review) }
            let results = await [first, second]
            #expect(results.filter { (try? $0.get()) != nil }.count == 1)
            #expect(await fixture.remote.createRequests.count == 1)

            // A later attempt is refused by state, before any request.
            await #expect(throws: ReleaseWorkflowError.wrongState(.draftCreated)) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            #expect(await fixture.remote.createRequests.count == 1)
            #expect(try await fixture.snapshots().count == 1)
        }

        @Test("After a timeout, nothing is created again until GitHub is read; the created draft is linked")
        func timeoutThenLink() async throws {
            let fixture = try await WorkflowFixture()
            await fixture.remote.setCreateBehavior(.timeoutAfterCreating)
            await #expect(throws: ReleaseWorkflowError.outcomeUnknown) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            #expect(try await fixture.currentPlan().status == .reconciliationNeeded)
            #expect(try await fixture.snapshots().map(\.state) == [.pending])

            await #expect(throws: ReleaseWorkflowError.wrongState(.reconciliationNeeded)) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .draftLinked && outcome.duplicateDrafts.isEmpty)
            #expect(try await fixture.currentPlan().status == .draftCreated)
            #expect(try await fixture.snapshots().map(\.state) == [.draftCreated])
            #expect(await fixture.remote.createRequests.count == 1)
        }

        @Test("After a timeout where GitHub created nothing, the plan is planned again")
        func timeoutNothingCreated() async throws {
            let fixture = try await WorkflowFixture()
            await fixture.remote.setCreateBehavior(.timeoutWithoutCreating)
            await #expect(throws: ReleaseWorkflowError.outcomeUnknown) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .noDraftFound)
            #expect(try await fixture.currentPlan().status == .planned)
            #expect(try await fixture.snapshots().isEmpty)

            // Trying again now works and sends the second request only now.
            await fixture.remote.setCreateBehavior(.succeed)
            try await fixture.workflow.createDraft(fixture.review)
            #expect(await fixture.remote.createRequests.count == 2)
        }

        @Test("Duplicate drafts on GitHub: the oldest is linked and the others are reported")
        func duplicateDraftsOnGitHub() async throws {
            let fixture = try await WorkflowFixture()
            await fixture.remote.setCreateBehavior(.timeoutAfterCreating)
            await #expect(throws: ReleaseWorkflowError.outcomeUnknown) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            // A delayed copy of the same request also landed.
            let late = await fixture.remote.addRelease(tag: "v1.1.0", target: targetSHA, draft: true)
            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .draftLinked)
            #expect(outcome.duplicateDrafts == [late])
            #expect(outcome.snapshot?.githubReleaseID != late.id)
        }

        @Test("If recording the draft fails, reconciliation links it without creating another")
        func failedSave() async throws {
            let fixture = try await WorkflowFixture(flakySave: true)
            await #expect(throws: ReleaseWorkflowError.self) { try await fixture.workflow.createDraft(fixture.review) }
            #expect(try await fixture.currentPlan().status == .reconciliationNeeded)

            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .draftLinked)
            #expect(try await fixture.currentPlan().status == .draftCreated)
            #expect(await fixture.remote.createRequests.count == 1)
        }

        @Test("A rejected request changes nothing")
        func rejected() async throws {
            let fixture = try await WorkflowFixture()
            await fixture.remote.setCreateBehavior(.reject)
            await #expect(throws: FakeGitHubError(message: "Validation Failed")) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            #expect(try await fixture.currentPlan().status == .planned)
            #expect(try await fixture.snapshots().isEmpty)
        }

        @Test("Conflicting tags and releases block the draft before anything is sent")
        func conflicts() async throws {
            let fixture = try await WorkflowFixture()
            await fixture.remote.setTag("v1.1.0", at: otherSHA)
            await #expect(throws: ReleaseWorkflowError.self) { try await fixture.workflow.createDraft(fixture.review) }

            let other = try await WorkflowFixture()
            await other.remote.addRelease(tag: "v1.1.0", target: "main", draft: true)
            let check = try await other.workflow.check(other.plan)
            #expect(check.blockingIssues.map(\.kind).count == 1)
            await #expect(throws: ReleaseWorkflowError.self) { try await other.workflow.createDraft(other.review) }

            #expect(await fixture.remote.createRequests.isEmpty)
            #expect(await other.remote.createRequests.isEmpty)
            #expect(try await fixture.currentPlan().status == .planned)

            // A tag that already points at the target commit is fine: GitHub uses it as is.
            let reuse = try await WorkflowFixture()
            await reuse.remote.setTag("v1.1.0", at: targetSHA)
            try await reuse.workflow.createDraft(reuse.review)
        }

        @Test("Incomplete tasks need explicit confirmation and are left unchanged")
        func incompleteTasks() async throws {
            let fixture = try await WorkflowFixture(openTasks: 2)
            await #expect(throws: ReleaseWorkflowError.incompleteTasksNotConfirmed(count: 2)) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            var review = fixture.review
            review.confirmsIncompleteTasks = true
            let snapshot = try await fixture.workflow.createDraft(review)
            #expect(snapshot.tasks.filter { !$0.isCompleted }.count == 2)
            let tasks = try await fixture.store.board.tasks(projectID: fixture.project.id)
            #expect(tasks.filter { $0.completedAt == nil }.count == 2)
        }

        @Test("A review that no longer matches the plan is refused")
        func outdatedReview() async throws {
            let fixture = try await WorkflowFixture()
            let review = fixture.review
            var plan = fixture.plan
            plan.changelogMarkdown = "Edited after review"
            _ = try await ReleasePlanService(repository: fixture.store.releasePlans).update(plan)
            await #expect(throws: ReleaseWorkflowError.reviewOutdated) {
                try await fixture.workflow.createDraft(review)
            }
            #expect(await fixture.remote.createRequests.isEmpty)
        }

        @Test("Publication is reported only after GitHub publishes and the tag is verified")
        func publication() async throws {
            let fixture = try await WorkflowFixture()
            let draft = try await fixture.workflow.createDraft(fixture.review)
            #expect(try await fixture.workflow.reconcile(fixture.plan).kind == .stillDraft)
            #expect(try await fixture.currentPlan().status == .draftCreated)

            await fixture.remote.publish(try #require(draft.githubReleaseID), body: "## Features\r\n\r\n- Login (#5)")
            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .published)
            let plan = try await fixture.currentPlan()
            #expect(plan.status == .published && plan.releasedAt != nil)
            let snapshot = try #require(try await fixture.snapshots().first)
            #expect(snapshot.state == .published && snapshot.publishedCommitSHA == targetSHA)
            #expect(snapshot.publishedNotesMarkdown == nil)
            #expect(snapshot.githubReleaseURL == repositoryURL.appending(path: "releases/tag/v1.1.0"))
            // Tasks are never completed or changed by a release.
            #expect(try await fixture.store.board.tasks(projectID: fixture.project.id).map(\.title) == ["Login screen"])
        }

        @Test("A published tag at another commit needs the user's decision")
        func mismatch() async throws {
            let fixture = try await WorkflowFixture()
            let draft = try await fixture.workflow.createDraft(fixture.review)
            // Someone pushed the tag elsewhere before the draft was published; GitHub keeps the existing tag.
            await fixture.remote.setTag("v1.1.0", at: otherSHA)
            await fixture.remote.publish(try #require(draft.githubReleaseID), body: "Edited on GitHub")

            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            guard case .publicationMismatch(let mismatch) = outcome.kind else {
                Issue.record("Expected a mismatch, got \(outcome.kind)")
                return
            }
            #expect(mismatch.publishedCommitSHA == otherSHA && mismatch.expectedCommitSHA == targetSHA)
            #expect(try await fixture.currentPlan().status == .reconciliationNeeded)
            #expect(try await fixture.snapshots().first?.state == .draftCreated)

            let accepted = try await fixture.workflow.acceptPublishedRelease(fixture.plan)
            #expect(accepted.state == .published && accepted.effectiveCommitSHA == otherSHA)
            #expect(accepted.targetCommitSHA == targetSHA)  // what was reviewed stays on record
            #expect(accepted.publishedNotesMarkdown == "Edited on GitHub")
            #expect(try await fixture.currentPlan().status == .published)
        }

        @Test("A draft deleted on GitHub is kept as abandoned and the plan can be drafted again")
        func deletedDraft() async throws {
            let fixture = try await WorkflowFixture()
            let draft = try await fixture.workflow.createDraft(fixture.review)
            await fixture.remote.delete(try #require(draft.githubReleaseID))

            #expect(try await fixture.workflow.reconcile(fixture.plan).kind == .draftDeleted)
            #expect(try await fixture.currentPlan().status == .planned)
            #expect(try await fixture.snapshots().map(\.state) == [.abandoned])

            try await fixture.workflow.createDraft(fixture.review)
            #expect(try await fixture.snapshots().map(\.state) == [.abandoned, .draftCreated])
        }

        @Test("A release published outside Relvora is detected and recorded")
        func externalRelease() async throws {
            let fixture = try await WorkflowFixture()
            let published = await fixture.remote.addRelease(
                tag: "v1.1.0", target: otherSHA, draft: false, body: "Written on GitHub")

            let outcome = try await fixture.workflow.reconcile(fixture.plan)
            #expect(outcome.kind == .publishedExternally(published))
            let check = try await fixture.workflow.check(fixture.plan)
            #expect(check.publishedRelease == published)
            #expect(!check.allowsDraft(confirmingIncompleteTasks: true))

            let snapshot = try await fixture.workflow.recordPublishedRelease(fixture.plan)
            #expect(snapshot.origin == .external && snapshot.state == .published)
            #expect(snapshot.releaseNotesMarkdown == "Written on GitHub" && snapshot.targetCommitSHA == otherSHA)
            #expect(snapshot.tasks.map(\.title) == ["Login screen"])
            let plan = try await fixture.currentPlan()
            #expect(plan.status == .published && plan.targetCommitSHA == otherSHA)
            #expect(await fixture.remote.createRequests.isEmpty)
        }
    }

    @Suite("Release snapshot store")
    struct ReleaseSnapshotStoreTests {
        @Test("The store allows only forward transitions, guarded by the plan's status")
        func guards() async throws {
            let fixture = try await WorkflowFixture()
            let snapshot = try await fixture.workflow.createDraft(fixture.review)
            let store = fixture.store.releaseSnapshots
            let url = repositoryURL

            // Replaying a transition is refused (fields are set once).
            await #expect(throws: PersistenceError.self) {
                try await store.record(
                    ReleaseRecord(
                        planID: fixture.plan.id, expectedStatus: .draftCreated, newStatus: .draftCreated,
                        operation: .transition(snapshotID: snapshot.id, .draftConfirmed(releaseID: 1, url: url)),
                        date: .now))
            }
            // A confirmed draft can't be discarded.
            await #expect(throws: PersistenceError.self) {
                try await store.record(
                    ReleaseRecord(
                        planID: fixture.plan.id, expectedStatus: .draftCreated, newStatus: .planned,
                        operation: .discardPending(snapshotID: snapshot.id), date: .now))
            }
            // A stale expectation is refused.
            await #expect(throws: PersistenceError.outdated(entity: "release plan")) {
                try await store.record(
                    ReleaseRecord(
                        planID: fixture.plan.id, expectedStatus: .planned, newStatus: .published, operation: .none,
                        date: .now))
            }
            #expect(try await fixture.snapshots() == [snapshot])
            #expect(try await fixture.currentPlan().status == .draftCreated)
            // Plans in workflow states can't be edited, cancelled, or deleted through the plan repository.
            await #expect(throws: PersistenceError.self) { try await fixture.store.releasePlans.save(fixture.plan) }
            await #expect(throws: PersistenceError.self) {
                try await fixture.store.releasePlans.deletePlan(id: fixture.plan.id)
            }
        }

        @Test("Snapshots are in backups, restore exactly, and are deleted with their project")
        func backupAndCascade() async throws {
            let fixture = try await WorkflowFixture()
            let draft = try await fixture.workflow.createDraft(fixture.review)
            await fixture.remote.publish(try #require(draft.githubReleaseID))
            _ = try await fixture.workflow.reconcile(fixture.plan)
            let published = try #require(try await fixture.snapshots().first)

            let document = try await BackupService(repository: fixture.store.backups).export(appVersion: nil)
            let decoded = try BackupService.inspect(try document.encoded()).document
            #expect(decoded.projects.first?.releaseSnapshots.count == 1)
            let restored = try PersistentStore.inMemory()
            try await BackupService(repository: restored.backups).restore(decoded)
            let copy = try #require(try await restored.releaseSnapshots.snapshots(projectID: fixture.project.id).first)
            // Backups store dates to the millisecond, so compare identity and content rather than exact dates.
            #expect(copy.tasks.map(\.id) == published.tasks.map(\.id))
            #expect(copy.tasks.map(\.title) == published.tasks.map(\.title))
            #expect(copy.releaseNotesMarkdown == published.releaseNotesMarkdown)
            #expect(copy.state == .published && copy.publishedCommitSHA == targetSHA)
            #expect(
                try await restored.releasePlans.plans(projectID: fixture.project.id).first?.tagName == "v1.1.0")

            try await fixture.store.projects.deleteProject(id: fixture.project.id)
            #expect(try await fixture.store.releaseSnapshots.allSnapshots().isEmpty)
        }

        @Test("A V2 store migrates to V3 with every record intact")
        func v2ToCurrent() async throws {
            let fixture = try #require(
                Bundle.module.url(forResource: "RelvoraV2", withExtension: "store", subdirectory: "Fixtures"))
            let directory = FileManager.default.temporaryDirectory.appending(path: "Migration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appending(path: "Relvora.store")
            try FileManager.default.copyItem(at: fixture, to: copy)

            let store = try PersistentStore.open(at: copy)
            let migrated = try await BackupService(repository: store.backups).export(appVersion: nil)
            let expectedURL = try #require(
                Bundle.module.url(forResource: "backup-v2", withExtension: "json", subdirectory: "Fixtures"))
            let expected = try BackupService.inspect(try Data(contentsOf: expectedURL)).document
            #expect(migrated.projects == expected.projects)
            let relvora = try #require(migrated.projects.first { $0.name == "Relvora" })
            #expect(relvora.repositoryConnections.map(\.name) == ["Release-Manager"])
            #expect(relvora.releasePlans.allSatisfy { $0.tagName == nil && $0.repositoryConnectionID == nil })
            #expect(relvora.releaseSnapshots.isEmpty)
        }
    }
}
