import Foundation
import RelvoraCore
import Testing

private let sha = String(repeating: "a", count: 40)
private let otherSHA = String(repeating: "b", count: 40)
private let repositoryURL = URL(string: "https://github.com/octo/app")!

private func release(_ id: Int64, tag: String, draft: Bool, target: String = sha) -> RemoteRelease {
    RemoteRelease(
        id: id, tagName: tag, name: nil, isDraft: draft, isPrerelease: false, createdAt: .now,
        publishedAt: draft ? nil : .now, targetCommitish: target,
        htmlURL: repositoryURL.appending(path: "releases/\(id)"), body: nil)
}

@Suite("Release checks")
struct ReleaseCheckTests {
    private let projectID = UUID()
    private let connection: RepositoryConnection
    private let plan: ReleasePlan

    init() {
        connection = RepositoryConnection(
            projectID: projectID, githubRepositoryID: 42, owner: "octo", name: "app", defaultBranch: "main",
            htmlURL: repositoryURL, isPrivate: false)
        plan = ReleasePlan(
            projectID: projectID, version: "1.1.0", repositoryConnectionID: connection.id, targetBranch: "main",
            targetCommitSHA: sha, tagName: "v1.1.0", changelogMarkdown: "## Features\n- Login")
    }

    private func task(done: Bool, in plan: ReleasePlan? = nil) -> ProjectTask {
        ProjectTask(
            projectID: projectID, columnID: UUID(), releasePlanID: (plan ?? self.plan).id, title: "Task", sortOrder: 1,
            completedAt: done ? .now : nil)
    }

    @Test("A complete plan has no local findings")
    func ready() {
        #expect(ReleaseChecker.localIssues(plan: plan, tasks: [task(done: true)], connection: connection).isEmpty)
    }

    @Test("Missing repository, commit, and tag block the draft; empty notes and open tasks warn")
    func localFindings() {
        var incomplete = ReleasePlan(projectID: projectID, version: "1.1.0")
        let kinds = ReleaseChecker.localIssues(plan: incomplete, tasks: [], connection: nil).map(\.kind)
        #expect(kinds == [.noRepository, .noTargetCommit, .noTag, .emptyNotes, .noTasks])

        incomplete.repositoryConnectionID = UUID()
        incomplete.tagName = "v1.1.0 final"
        let issues = ReleaseChecker.localIssues(
            plan: incomplete, tasks: [task(done: false, in: incomplete), task(done: true, in: incomplete)],
            connection: nil)
        #expect(issues.map(\.kind).contains(.repositoryDisconnected))
        #expect(issues.map(\.kind).contains(.invalidTag("v1.1.0 final")))
        #expect(issues.contains { $0.kind == .incompleteTasks(count: 1) && $0.severity == .warning })
    }

    @Test("Every step of the release checklist must be ticked before the draft")
    func checklist() {
        let steps = ["Test on a clean Mac", "Update screenshots", "Tell support"].enumerated().map {
            ReleaseStep(projectID: projectID, title: $1, sortOrder: Double($0 + 1))
        }
        var plan = plan
        let none = ReleaseChecker.localIssues(
            plan: plan, tasks: [task(done: true)], connection: connection, steps: steps)
        #expect(none.map(\.kind) == [.checklistIncomplete(remaining: 3, total: 3)])
        #expect(none.first?.severity == .blocking)
        #expect(none.first?.message == "The release checklist isn’t done yet: tick its 3 steps first.")

        plan.completedStepIDs = [steps[0].id, steps[2].id, UUID()]  // a deleted step's tick is ignored
        let one = ReleaseChecker.localIssues(
            plan: plan, tasks: [task(done: true)], connection: connection, steps: steps)
        #expect(one.first?.message == "1 of 3 release checklist steps isn’t done yet.")
        #expect(ReleaseChecklist.remaining(steps, plan: plan) == [steps[1]])

        plan.completedStepIDs.insert(steps[1].id)
        #expect(
            ReleaseChecker.localIssues(plan: plan, tasks: [task(done: true)], connection: connection, steps: steps)
                .isEmpty)
        #expect(ReleaseChecklist.snapshot(steps, plan: plan).allSatisfy { $0.isDone })
    }

    @Test("Saving a checklist trims titles, drops blank steps, renumbers, and keeps IDs")
    func checklistValidation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let kept = ReleaseStep(projectID: projectID, title: "Tell support", sortOrder: 7, createdAt: .distantPast)
        let edited = [
            ReleaseStep(projectID: projectID, title: "  Test on a clean Mac ", sortOrder: 0), kept,
            ReleaseStep(projectID: projectID, title: "   ", sortOrder: 2),
        ]
        let saved = try ReleaseChecklist.validated(edited, projectID: projectID, now: now)
        #expect(saved.map(\.title) == ["Test on a clean Mac", "Tell support"])
        #expect(saved.map(\.sortOrder) == [1, 2])
        #expect(saved[1].id == kept.id && saved[1].updatedAt == now)

        let long = ReleaseStep(projectID: projectID, title: String(repeating: "x", count: 201), sortOrder: 1)
        #expect(throws: ValidationError.titleTooLong(maximum: 200)) {
            try ReleaseChecklist.validated([long], projectID: projectID, now: now)
        }
    }

    @Test("A tag that doesn't match the version is a warning")
    func tagVersionMismatch() {
        var plan = plan
        plan.tagName = "v1.2.0"
        let issues = ReleaseChecker.localIssues(plan: plan, tasks: [task(done: true)], connection: connection)
        #expect(issues.map(\.kind) == [.tagDoesNotMatchVersion(tag: "v1.2.0", version: "1.1.0")])
        plan.version = "Spring Preview"
        plan.tagName = "Spring-Preview"
        #expect(ReleaseChecker.localIssues(plan: plan, tasks: [task(done: true)], connection: connection).isEmpty)
    }

    @Test("An existing tag elsewhere, a published release, or a draft for the tag block the draft")
    func remoteConflicts() {
        let moved = ReleaseChecker.remoteIssues(
            plan: plan, releases: [], releasesTruncated: false, tagCommitSHA: otherSHA)
        #expect(moved.map(\.kind) == [.tagExists(tag: "v1.1.0", commitSHA: otherSHA)])
        #expect(moved.first?.severity == .blocking)

        let same = ReleaseChecker.remoteIssues(plan: plan, releases: [], releasesTruncated: false, tagCommitSHA: sha)
        #expect(same.map(\.severity) == [.note])

        let releases = [release(1, tag: "v1.1.0", draft: true), release(2, tag: "v1.1.0", draft: false)]
        let kinds = ReleaseChecker.remoteIssues(
            plan: plan, releases: releases, releasesTruncated: true, tagCommitSHA: nil
        ).map(\.kind)
        #expect(
            kinds == [
                .draftExists(tag: "v1.1.0", url: releases[0].htmlURL),
                .releasePublished(tag: "v1.1.0", url: releases[1].htmlURL),
                .releaseListIncomplete,
                .versionNotNewer(latest: "v1.1.0"),
            ])
    }

    @Test("A version older than the latest published release warns")
    func versionOrder() {
        let releases = [release(1, tag: "v2.0.0", draft: false), release(2, tag: "v9.0.0", draft: true)]
        let kinds = ReleaseChecker.remoteIssues(
            plan: plan, releases: releases, releasesTruncated: false, tagCommitSHA: nil
        ).map(\.kind)
        #expect(kinds == [.versionNotNewer(latest: "v2.0.0")])
    }

    @Test("A draft needs a GitHub check, nothing blocking, and confirmation of incomplete tasks")
    func allowsDraft() {
        let local = ReleaseCheck(
            issues: [.init(.incompleteTasks(count: 2))], repository: nil, publishedRelease: nil, checkedAt: .now)
        #expect(!local.allowsDraft(confirmingIncompleteTasks: true))

        let github = GitHubRepository(
            id: 42, owner: "octo", name: "app", defaultBranch: "main", htmlURL: repositoryURL, isPrivate: false)
        let remote = ReleaseCheck(
            issues: [.init(.incompleteTasks(count: 2)), .init(.tagExistsAtTarget(tag: "v1.1.0"))],
            repository: github, publishedRelease: nil, checkedAt: .now)
        #expect(remote.incompleteTaskCount == 2)
        #expect(!remote.allowsDraft(confirmingIncompleteTasks: false))
        #expect(remote.allowsDraft(confirmingIncompleteTasks: true))

        let blocked = ReleaseCheck(
            issues: [.init(.noTag)], repository: github, publishedRelease: nil, checkedAt: .now)
        #expect(!blocked.allowsDraft(confirmingIncompleteTasks: true))
    }
}

@Suite("Release plan targets")
struct ReleaseTargetTests {
    @Test(
        "Tag names follow Git's rules",
        arguments: [
            ("v1.4.0", true), ("release/2026-10", true), ("v2.0.0-beta.1+build.5", true), ("Spring-Preview", true),
            ("", false), ("v1 0", false), ("-v1", false), ("v1..0", false), ("v1.lock", false), ("a/.b", false),
            ("v1/", false), ("v1.", false), ("v1~1", false), ("v1:0", false), ("v1@{0}", false), ("@", false),
            ("a//b", false), ("tab\tname", false),
        ])
    func tagNames(name: String, valid: Bool) {
        #expect(GitRefName.isValidTag(name) == valid)
    }

    @Test("Only full lowercase SHAs are accepted")
    func shas() {
        #expect(GitRefName.isFullCommitSHA(sha))
        #expect(!GitRefName.isFullCommitSHA("abc1234"))
        #expect(!GitRefName.isFullCommitSHA(sha.uppercased()))
        #expect(!GitRefName.isFullCommitSHA(String(repeating: "g", count: 40)))
    }

    @Test("Suggested tags, pre-release flags, and release names follow the version")
    func derived() {
        var plan = ReleasePlan(projectID: UUID(), version: "2.0.0-beta.1", title: "Boards")
        #expect(plan.suggestedTagName == "v2.0.0-beta.1")
        #expect(plan.isPrerelease)
        #expect(plan.releaseName == "2.0.0-beta.1 – Boards")
        plan.version = "Spring Preview 2"
        plan.title = nil
        #expect(plan.suggestedTagName == "Spring-Preview-2")
        #expect(!plan.isPrerelease)
        #expect(plan.releaseName == "Spring Preview 2")
    }

    @Test("Plans normalize targets and reject bad tags, SHAs, and over-long notes")
    func validation() throws {
        var plan = ReleasePlan(projectID: UUID(), version: "1.0.0")
        plan.tagName = "  v1.0.0 "
        plan.targetCommitSHA = sha.uppercased()
        let normalized = try ReleasePlanRules.validated(plan, existing: [])
        #expect(normalized.tagName == "v1.0.0")
        #expect(normalized.targetCommitSHA == sha)

        plan.tagName = "v1 0"
        #expect(throws: ValidationError.invalidTagName("v1 0")) { try ReleasePlanRules.validated(plan, existing: []) }
        plan.tagName = nil
        plan.targetCommitSHA = "abc1234"
        #expect(throws: ValidationError.invalidCommitSHA("abc1234")) {
            try ReleasePlanRules.validated(plan, existing: [])
        }
        plan.targetCommitSHA = nil
        plan.changelogMarkdown = String(repeating: "x", count: ReleaseNotes.maximumLength + 1)
        #expect(throws: ValidationError.releaseNotesTooLong(maximum: ReleaseNotes.maximumLength)) {
            try ReleasePlanRules.validated(plan, existing: [])
        }
    }
}

@Suite("Release snapshots")
struct ReleaseSnapshotTests {
    private func snapshot() -> ReleaseSnapshot {
        ReleaseSnapshot(
            projectID: UUID(), releasePlanID: UUID(), origin: .relvoraDraft, version: "1.0.0", title: nil,
            releaseName: "1.0.0", tagName: "v1.0.0", targetCommitSHA: sha, targetBranch: "main", isPrerelease: false,
            releaseNotesMarkdown: "## Fixes\n- Crash", tasks: [], changes: nil, githubRepositoryID: 42,
            repositoryFullName: "octo/app", repositoryURL: repositoryURL, snapshotCreatedAt: .now)
    }

    @Test("Lifecycle moves forward only, and each field is set once")
    func transitions() throws {
        let pending = snapshot()
        let draftURL = repositoryURL.appending(path: "releases/tag/untagged-1")
        #expect(pending.applying(.abandoned, at: .now) == nil)
        let draft = try #require(pending.applying(.draftConfirmed(releaseID: 7, url: draftURL), at: .now))
        #expect(draft.state == .draftCreated && draft.githubReleaseID == 7)
        #expect(draft.applying(.draftConfirmed(releaseID: 8, url: draftURL), at: .now) == nil)

        let tagURL = repositoryURL.appending(path: "releases/tag/v1.0.0")
        let published = try #require(
            draft.applying(
                .published(
                    at: .now, url: tagURL, notes: "## Fixes\r\n- Crash  \r\n", tagName: "v1.0.0", commitSHA: sha),
                at: .now))
        #expect(published.state == .published)
        #expect(published.publishedNotesMarkdown == nil)  // only line endings and whitespace differ
        #expect(published.publishedTagName == nil)
        #expect(published.githubReleaseURL == tagURL)
        #expect(published.applying(.abandoned, at: .now) == nil)
        #expect(
            published.applying(.published(at: .now, url: tagURL, notes: nil, tagName: "x", commitSHA: sha), at: .now)
                == nil)

        // Content never changes through a transition.
        #expect(published.releaseNotesMarkdown == pending.releaseNotesMarkdown)
        #expect(published.tagName == pending.tagName && published.targetCommitSHA == pending.targetCommitSHA)
    }

    @Test("Notes edited on GitHub and an accepted tag change are recorded beside the original")
    func publishedDifferences() throws {
        let draft = try #require(
            snapshot().applying(.draftConfirmed(releaseID: 7, url: repositoryURL), at: .now))
        let published = try #require(
            draft.applying(
                .published(at: .now, url: repositoryURL, notes: "Edited", tagName: "v1.0.1", commitSHA: otherSHA),
                at: .now))
        #expect(published.publishedNotesMarkdown == "Edited")
        #expect(published.effectiveNotesMarkdown == "Edited")
        #expect(published.releaseNotesMarkdown == "## Fixes\n- Crash")
        #expect(published.effectiveTagName == "v1.0.1")
        #expect(published.effectiveCommitSHA == otherSHA)
    }
}
