import Foundation
import RelvoraCore
import Testing

@testable import RelvoraPersistence

extension WorkflowFixture {
    /// Creates the draft and returns the preview the user would confirm.
    func draftAndPreview() async throws -> PublishPreview {
        try await workflow.createDraft(review)
        return try #require(try await workflow.publishPreview(try await currentPlan()))
    }

    func draftID() async throws -> Int64 {
        try #require(try await snapshots().first?.githubReleaseID)
    }
}

extension StoreTests {
    @Suite("Publishing from Relvora")
    struct PublishWorkflowTests {
        @Test("Publishing the confirmed draft creates the tag at the reviewed commit, verified")
        func publish() async throws {
            let fixture = try await WorkflowFixture()
            let preview = try await fixture.draftAndPreview()
            #expect(preview.canPublish && preview.existingTagCommitSHA == nil && !preview.notesEditedOnGitHub)

            let outcome = try await fixture.workflow.publishDraft(try await fixture.currentPlan(), confirmed: preview)
            #expect(outcome.kind == .published)
            #expect(await fixture.remote.publishRequests == [try await fixture.draftID()])
            #expect(try await fixture.currentPlan().status == .published)
            let snapshot = try #require(try await fixture.snapshots().first)
            #expect(snapshot.state == .published && snapshot.publishedCommitSHA == targetSHA)
            #expect(try await fixture.remote.tagCommitSHA(of: preview.repository, tag: "v1.1.0") == targetSHA)
        }

        @Test("A tag elsewhere, an edited draft, or an existing release blocks publishing before anything is sent")
        func problems() async throws {
            let tagElsewhere = try await WorkflowFixture()
            try await tagElsewhere.workflow.createDraft(tagElsewhere.review)
            await tagElsewhere.remote.setTag("v1.1.0", at: otherSHA)
            let blocked = try #require(try await tagElsewhere.workflow.publishPreview(tagElsewhere.plan))
            #expect(blocked.problems == [.tagExistsElsewhere(commitSHA: otherSHA)])
            await #expect(throws: ReleaseWorkflowError.self) {
                try await tagElsewhere.workflow.publishDraft(tagElsewhere.plan, confirmed: blocked)
            }

            let edited = try await WorkflowFixture()
            try await edited.workflow.createDraft(edited.review)
            await edited.remote.editDraft(try await edited.draftID(), tag: "v1.1.1", target: "main")
            let changed = try #require(try await edited.workflow.publishPreview(edited.plan))
            #expect(changed.problems == [.tagChanged(to: "v1.1.1"), .targetChanged(to: "main")])

            let released = try await WorkflowFixture()
            try await released.workflow.createDraft(released.review)
            await released.remote.addRelease(tag: "v1.1.0", target: targetSHA, draft: false)
            let existing = try #require(try await released.workflow.publishPreview(released.plan))
            #expect(existing.problems == [.tagAlreadyReleased])

            for fixture in [tagElsewhere, edited, released] {
                #expect(await fixture.remote.publishRequests.isEmpty)
                #expect(try await fixture.currentPlan().status == .draftCreated)
            }
        }

        @Test("A draft edited on GitHub after it was confirmed is refused")
        func outdatedConfirmation() async throws {
            let fixture = try await WorkflowFixture()
            let preview = try await fixture.draftAndPreview()
            await fixture.remote.editDraft(try await fixture.draftID(), body: "Edited on GitHub")
            await #expect(throws: ReleaseWorkflowError.reviewOutdated) {
                try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview)
            }
            #expect(await fixture.remote.publishRequests.isEmpty)

            // A new preview shows the edit, and publishing it works.
            let current = try #require(try await fixture.workflow.publishPreview(fixture.plan))
            #expect(current.notesEditedOnGitHub && current.canPublish)
            #expect(try await fixture.workflow.publishDraft(fixture.plan, confirmed: current).kind == .published)
            #expect(try await fixture.snapshots().first?.publishedNotesMarkdown == "Edited on GitHub")
        }

        @Test("After a lost response, Check Publication verifies the release; publishing again sends nothing")
        func lostResponse() async throws {
            let fixture = try await WorkflowFixture()
            let preview = try await fixture.draftAndPreview()
            await fixture.remote.setPublishBehavior(.timeoutAfterPublishing)
            await #expect(throws: ReleaseWorkflowError.publishOutcomeUnknown) {
                try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview)
            }
            #expect(try await fixture.currentPlan().status == .draftCreated)

            // Publishing again finds it published on GitHub and records it without another request.
            #expect(try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview).kind == .published)
            #expect(await fixture.remote.publishRequests.count == 1)
            #expect(try await fixture.currentPlan().status == .published)
        }

        @Test("A publish that never reached GitHub can be sent again")
        func notSent() async throws {
            let fixture = try await WorkflowFixture()
            let preview = try await fixture.draftAndPreview()
            await fixture.remote.setPublishBehavior(.timeoutWithoutPublishing)
            await #expect(throws: ReleaseWorkflowError.publishOutcomeUnknown) {
                try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview)
            }
            #expect(try await fixture.workflow.reconcile(fixture.plan).kind == .stillDraft)

            await fixture.remote.setPublishBehavior(.succeed)
            #expect(try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview).kind == .published)
            #expect(await fixture.remote.publishRequests.count == 2)
        }

        @Test("The release checklist blocks the draft until every step is ticked, then is frozen with the release")
        func checklist() async throws {
            let fixture = try await WorkflowFixture()
            let service = ReleaseChecklistService(steps: fixture.store.releaseSteps, plans: fixture.store.releasePlans)
            let steps = try await service.save(
                ["Test on a clean Mac", "Update screenshots"].map {
                    ReleaseStep(projectID: fixture.project.id, title: $0, sortOrder: 0)
                }, projectID: fixture.project.id)
            await #expect(
                throws: ReleaseWorkflowError.notReady("The release checklist isn’t done yet: tick its 2 steps first.")
            ) {
                try await fixture.workflow.createDraft(fixture.review)
            }
            #expect(await fixture.remote.createRequests.isEmpty)

            var plan = try await fixture.currentPlan()
            for step in steps { plan = try await service.setStep(step.id, done: true, on: plan) }
            let snapshot = try await fixture.workflow.createDraft(fixture.review)
            #expect(snapshot.checklist.map(\.title) == ["Test on a clean Mac", "Update screenshots"])
            #expect(snapshot.checklist.allSatisfy { $0.isDone })

            // Frozen: later checklist edits don't change the record.
            _ = try await service.save([], projectID: fixture.project.id)
            #expect(try await fixture.snapshots().first?.checklist == snapshot.checklist)
        }

        @Test("A rejected publish leaves the draft as it was")
        func rejected() async throws {
            let fixture = try await WorkflowFixture()
            let preview = try await fixture.draftAndPreview()
            await fixture.remote.setPublishBehavior(.reject)
            await #expect(throws: FakeGitHubError(message: "Validation Failed")) {
                try await fixture.workflow.publishDraft(fixture.plan, confirmed: preview)
            }
            #expect(try await fixture.currentPlan().status == .draftCreated)
            #expect(try await fixture.snapshots().first?.state == .draftCreated)
        }

        @Test("A draft published or deleted on GitHub meanwhile is recorded instead of sent")
        func changedMeanwhile() async throws {
            let published = try await WorkflowFixture()
            let preview = try await published.draftAndPreview()
            await published.remote.publish(try await published.draftID())
            #expect(try await published.workflow.publishDraft(published.plan, confirmed: preview).kind == .published)

            let deleted = try await WorkflowFixture()
            let gone = try await deleted.draftAndPreview()
            await deleted.remote.delete(try await deleted.draftID())
            #expect(try await deleted.workflow.publishDraft(deleted.plan, confirmed: gone).kind == .draftDeleted)
            #expect(try await deleted.currentPlan().status == .planned)

            for fixture in [published, deleted] { #expect(await fixture.remote.publishRequests.isEmpty) }
        }
    }
}
