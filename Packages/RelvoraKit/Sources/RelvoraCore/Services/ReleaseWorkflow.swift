import Foundation

/// What the user confirmed before creating a draft. The workflow refuses to create a draft if the stored plan no
/// longer matches it.
public struct ReleaseReview: Sendable, Equatable {
    public let planID: UUID
    public let projectID: UUID
    public let githubRepositoryID: Int64
    public let repositoryFullName: String
    public let tagName: String
    public let targetCommitSHA: String
    public let targetBranch: String?
    public let releaseName: String
    public let notes: String
    public let isPrerelease: Bool
    public let changes: ReleaseChangeSummary?
    /// The user chose to release with incomplete tasks.
    public var confirmsIncompleteTasks: Bool

    /// `nil` until the plan has a repository, tag, and target commit.
    public init?(
        plan: ReleasePlan, connection: RepositoryConnection, changes: ReleaseChangeSummary?,
        confirmsIncompleteTasks: Bool = false
    ) {
        guard plan.repositoryConnectionID == connection.id, let tag = plan.tagName, let sha = plan.targetCommitSHA
        else { return nil }
        self.planID = plan.id
        self.projectID = plan.projectID
        self.githubRepositoryID = connection.githubRepositoryID
        self.repositoryFullName = connection.fullName
        self.tagName = tag
        self.targetCommitSHA = sha
        self.targetBranch = plan.targetBranch
        self.releaseName = plan.releaseName
        self.notes = plan.changelogMarkdown
        self.isPrerelease = plan.isPrerelease
        self.changes = changes
        self.confirmsIncompleteTasks = confirmsIncompleteTasks
    }

    func matches(_ plan: ReleasePlan, connection: RepositoryConnection) -> Bool {
        plan.id == planID && connection.githubRepositoryID == githubRepositoryID && plan.tagName == tagName
            && plan.targetCommitSHA == targetCommitSHA && plan.releaseName == releaseName
            && plan.changelogMarkdown == notes && plan.isPrerelease == isPrerelease
    }

    var request: DraftReleaseRequest {
        DraftReleaseRequest(
            tagName: tagName, targetCommitSHA: targetCommitSHA, name: releaseName, body: notes,
            isPrerelease: isPrerelease)
    }
}

/// The published tag doesn't match what was reviewed.
public struct PublicationMismatch: Sendable, Equatable {
    public let expectedTag: String
    public let publishedTag: String
    public let expectedCommitSHA: String
    /// `nil` when the published tag couldn't be found.
    public let publishedCommitSHA: String?
}

/// Why a draft can't be published as it stands on GitHub.
public enum PublishProblem: Sendable, Equatable {
    /// The draft's tag was changed on GitHub.
    case tagChanged(to: String)
    /// The draft's target was changed on GitHub.
    case targetChanged(to: String)
    /// The tag exists at another commit. Publishing would attach the release to it, and Relvora never moves tags.
    case tagExistsElsewhere(commitSHA: String)
    /// Another published release already has the tag.
    case tagAlreadyReleased

    public func message(tag: String, commitSHA: String) -> String {
        switch self {
        case .tagChanged(let newTag): "On GitHub, the draft’s tag was changed from \(tag) to \(newTag)."
        case .targetChanged(let target):
            "On GitHub, the draft’s target was changed from \(commitSHA.prefix(7)) to \(target.prefix(12))."
        case .tagExistsElsewhere(let sha):
            "The tag \(tag) already exists at \(sha.prefix(7)), not at the reviewed commit \(commitSHA.prefix(7)). "
                + "Relvora never moves tags."
        case .tagAlreadyReleased: "GitHub already has a published release for \(tag)."
        }
    }
}

/// The draft as GitHub has it now, shown for confirmation before it is published.
public struct PublishPreview: Sendable, Equatable, Identifiable {
    public let snapshot: ReleaseSnapshot
    public let draft: RemoteRelease
    public let repository: GitHubRepository
    /// The commit the tag already points at; `nil` when GitHub will create the tag.
    public let existingTagCommitSHA: String?
    /// Empty when the draft can be published.
    public let problems: [PublishProblem]

    public var id: UUID { snapshot.id }
    public var canPublish: Bool { problems.isEmpty }
    public var problemMessages: [String] {
        problems.map { $0.message(tag: snapshot.tagName, commitSHA: snapshot.targetCommitSHA) }
    }

    /// The notes on GitHub differ from those Relvora put in the draft (ignoring line endings and trailing spaces).
    public var notesEditedOnGitHub: Bool {
        ReleaseNotes.normalized(draft.body ?? "") != ReleaseNotes.normalized(snapshot.releaseNotesMarkdown)
    }

    /// Whether GitHub still has the draft exactly as confirmed.
    func confirms(_ current: PublishPreview) -> Bool {
        current.snapshot.id == snapshot.id && current.draft.id == draft.id && current.draft.isDraft
            && current.draft.tagName == draft.tagName && current.draft.targetCommitish == draft.targetCommitish
            && current.draft.name == draft.name && current.draft.body == draft.body
            && current.draft.isPrerelease == draft.isPrerelease
    }
}

public struct ReconcileOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// GitHub has no draft from the unconfirmed request; the plan is `planned` again.
        case noDraftFound
        /// The unconfirmed request did create a draft; it is now linked.
        case draftLinked
        case stillDraft
        /// Publication verified: the tag points at the reviewed commit.
        case published
        /// Published, but the tag or its commit differs from what was reviewed. The plan needs the user's decision.
        case publicationMismatch(PublicationMismatch)
        /// The draft was deleted on GitHub; the snapshot is kept as abandoned and the plan is `planned` again.
        case draftDeleted
        /// GitHub already has a published release for the plan's tag, created outside Relvora.
        case publishedExternally(RemoteRelease)
        case nothingToCheck
    }

    public let kind: Kind
    public let snapshot: ReleaseSnapshot?
    /// Extra drafts GitHub created for the same tag and commit. Delete them on GitHub.
    public let duplicateDrafts: [RemoteRelease]
    /// Changes made to the draft on GitHub, worth knowing before it is published.
    public let notes: [String]

    init(_ kind: Kind, snapshot: ReleaseSnapshot? = nil, duplicateDrafts: [RemoteRelease] = [], notes: [String] = []) {
        self.kind = kind
        self.snapshot = snapshot
        self.duplicateDrafts = duplicateDrafts
        self.notes = notes
    }
}

public enum ReleaseWorkflowError: Error, Sendable, Equatable, LocalizedError {
    case notReady(String)
    case incompleteTasksNotConfirmed(count: Int)
    case reviewOutdated
    case wrongState(ReleasePlanStatus)
    case repositoryNotConnected
    /// The create request may or may not have reached GitHub. The plan needs reconciliation.
    case outcomeUnknown
    /// The draft exists on GitHub, but recording it locally failed. The plan needs reconciliation.
    case draftNotSaved(URL)
    case cannotVerify(String)
    case noPublishedRelease(tag: String)
    case cannotPublish(String)
    case publishOutcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .notReady(let reason): "The release isn’t ready: \(reason)"
        case .incompleteTasksNotConfirmed(let count):
            "\(count) \(count == 1 ? "task isn’t" : "tasks aren’t") complete."
        case .reviewOutdated: "The release changed after you reviewed it."
        case .wrongState(let status): "This release plan is \(status.title.lowercased())."
        case .repositoryNotConnected: "The release plan has no connected repository."
        case .outcomeUnknown: "GitHub didn’t confirm whether the draft was created."
        case .draftNotSaved: "The draft was created on GitHub, but Relvora couldn’t record it."
        case .cannotVerify(let reason): "Relvora couldn’t verify the release on GitHub: \(reason)"
        case .noPublishedRelease(let tag): "GitHub has no published release for \(tag)."
        case .cannotPublish(let reason): "The draft can’t be published: \(reason)"
        case .publishOutcomeUnknown: "GitHub didn’t confirm whether the release was published."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notReady: "Fix the issues shown in the release check, then try again."
        case .incompleteTasksNotConfirmed: "Confirm that you want to release with incomplete tasks."
        case .reviewOutdated: "Review the release again."
        case .wrongState: "Check GitHub to see the release’s current state."
        case .repositoryNotConnected: "Choose a repository for the release."
        case .outcomeUnknown, .draftNotSaved:
            "Choose Check GitHub. Relvora reads GitHub before anything is created again, so no duplicate is made."
        case .cannotVerify: "Try again later."
        case .noPublishedRelease: "Publish the release on GitHub first, or create a draft from Relvora."
        case .cannotPublish:
            "Fix the draft on GitHub, or delete it there, choose Check Publication, and create a new draft."
        case .publishOutcomeUnknown:
            "Choose Check Publication. Publishing again is safe: it can’t create a second release."
        }
    }
}

/// The release workflow: check, create a GitHub draft, publish it, and reconcile with GitHub until publication is
/// verified.
///
/// Safety rules (PRODUCT_SPEC §4):
/// - A release is always a draft first. It is published only after the user confirms the draft as GitHub has it
///   (here, or on GitHub), and reported published only after the tag is verified at the reviewed commit.
/// - The draft's intent is saved *before* the create request (plan `reconciliationNeeded` with a `pending`
///   snapshot). If the app quits, times out, or fails to save afterwards, the next step reads GitHub before
///   anything else can be created. Publishing needs no intent: it is idempotent, so GitHub is simply read again.
/// - Relvora never moves or deletes a tag. A tag is created only by GitHub, when a draft is published, at the
///   reviewed commit; a draft whose tag exists at another commit is never published.
/// - Tasks are never changed.
public struct ReleaseWorkflow: Sendable {
    private let plans: any ReleasePlanRepository
    private let snapshots: any ReleaseSnapshotRepository
    private let board: any BoardRepository
    private let connections: any RepositoryConnectionRepository
    private let steps: any ReleaseStepRepository
    private let remote: any ReleaseRemote
    private let now: @Sendable () -> Date
    /// How long to wait for a just-published tag to be readable before verifying it.
    private let tagWait: Duration

    public init(
        plans: any ReleasePlanRepository,
        snapshots: any ReleaseSnapshotRepository,
        board: any BoardRepository,
        connections: any RepositoryConnectionRepository,
        steps: any ReleaseStepRepository,
        remote: any ReleaseRemote,
        now: @escaping @Sendable () -> Date = { .now },
        tagWait: Duration = .seconds(1)
    ) {
        self.plans = plans
        self.snapshots = snapshots
        self.board = board
        self.connections = connections
        self.steps = steps
        self.remote = remote
        self.now = now
        self.tagWait = tagWait
    }

    // MARK: Checking

    /// Local and GitHub findings for a plan. Reads only.
    public func check(_ plan: ReleasePlan) async throws -> ReleaseCheck {
        let tasks = try await board.tasks(projectID: plan.projectID)
        let connection = try await connection(of: plan)
        let steps = try await steps.steps(projectID: plan.projectID)
        var issues = ReleaseChecker.localIssues(plan: plan, tasks: tasks, connection: connection, steps: steps)
        guard let connection else {
            return ReleaseCheck(issues: issues, repository: nil, publishedRelease: nil, checkedAt: now())
        }
        let repository = try await remote.repository(id: connection.githubRepositoryID)
        let (releases, truncated) = try await remote.releases(of: repository)
        var tagSHA: String?
        if let tag = plan.tagName, GitRefName.isValidTag(tag) {
            tagSHA = try await remote.tagCommitSHA(of: repository, tag: tag)
        }
        issues += ReleaseChecker.remoteIssues(
            plan: plan, releases: releases, releasesTruncated: truncated, tagCommitSHA: tagSHA)
        let published = releases.first { $0.tagName == plan.tagName && !$0.isDraft }
        return ReleaseCheck(issues: issues, repository: repository, publishedRelease: published, checkedAt: now())
    }

    // MARK: Creating the draft

    /// Creates the GitHub draft the user reviewed and records the snapshot. Checks GitHub again first.
    @discardableResult
    public func createDraft(_ review: ReleaseReview) async throws -> ReleaseSnapshot {
        let plan = try await currentPlan(review.planID, projectID: review.projectID)
        guard plan.status == .planned else { throw ReleaseWorkflowError.wrongState(plan.status) }
        guard let connection = try await connection(of: plan) else { throw ReleaseWorkflowError.repositoryNotConnected }
        guard review.matches(plan, connection: connection) else { throw ReleaseWorkflowError.reviewOutdated }

        let check = try await check(plan)
        if let blocking = check.blockingIssues.first { throw ReleaseWorkflowError.notReady(blocking.message) }
        guard check.incompleteTaskCount == 0 || review.confirmsIncompleteTasks else {
            throw ReleaseWorkflowError.incompleteTasksNotConfirmed(count: check.incompleteTaskCount)
        }
        guard let repository = check.repository else { throw ReleaseWorkflowError.repositoryNotConnected }

        let snapshot = ReleaseSnapshot(
            projectID: plan.projectID,
            releasePlanID: plan.id,
            origin: .relvoraDraft,
            version: plan.version,
            title: plan.title,
            releaseName: review.releaseName,
            tagName: review.tagName,
            targetCommitSHA: review.targetCommitSHA,
            targetBranch: review.targetBranch,
            isPrerelease: review.isPrerelease,
            releaseNotesMarkdown: review.notes,
            tasks: try await frozenTasks(of: plan),
            changes: review.changes,
            checklist: ReleaseChecklist.snapshot(try await steps.steps(projectID: plan.projectID), plan: plan),
            githubRepositoryID: repository.id,
            repositoryFullName: repository.fullName,
            repositoryURL: repository.htmlURL,
            snapshotCreatedAt: now()
        )
        // Intent first. Fails with `outdated` if another attempt already started, so only one request is sent.
        try await snapshots.record(
            ReleaseRecord(
                planID: plan.id, expectedStatus: .planned, newStatus: .reconciliationNeeded,
                operation: .insert(snapshot), date: now()))

        switch await remote.createDraftRelease(in: repository, review.request) {
        case .created(let release):
            let transition = SnapshotTransition.draftConfirmed(releaseID: release.id, url: release.htmlURL)
            let date = now()
            do {
                try await snapshots.record(
                    ReleaseRecord(
                        planID: plan.id, expectedStatus: .reconciliationNeeded, newStatus: .draftCreated,
                        operation: .transition(snapshotID: snapshot.id, transition), date: date))
            } catch {
                throw ReleaseWorkflowError.draftNotSaved(release.htmlURL)
            }
            return snapshot.applying(transition, at: date)!
        case .rejected(let error):
            // Nothing was created. If this save fails too, the plan stays in reconciliation, which also resolves
            // to `planned` once GitHub is read.
            try? await snapshots.record(
                ReleaseRecord(
                    planID: plan.id, expectedStatus: .reconciliationNeeded, newStatus: .planned,
                    operation: .discardPending(snapshotID: snapshot.id), date: now()))
            throw error
        case .unknown:
            throw ReleaseWorkflowError.outcomeUnknown
        }
    }

    // MARK: Publishing

    /// The plan's draft as GitHub has it now, with anything that blocks publishing it. Reads only. `nil` when GitHub
    /// no longer has it as a draft (deleted or already published): `reconcile` records what happened.
    public func publishPreview(_ plan: ReleasePlan) async throws -> PublishPreview? {
        let plan = try await currentPlan(plan.id, projectID: plan.projectID)
        guard plan.status == .draftCreated else { throw ReleaseWorkflowError.wrongState(plan.status) }
        guard
            let snapshot = try await snapshots.snapshots(projectID: plan.projectID)
                .first(where: { $0.releasePlanID == plan.id && $0.state == .draftCreated }),
            let releaseID = snapshot.githubReleaseID
        else { throw ReleaseWorkflowError.wrongState(plan.status) }
        let repository = try await remote.repository(id: snapshot.githubRepositoryID)
        guard let draft = try await remote.release(of: repository, id: releaseID), draft.isDraft else { return nil }

        var problems: [PublishProblem] = []
        if draft.tagName != snapshot.tagName { problems.append(.tagChanged(to: draft.tagName)) }
        if draft.targetCommitish != snapshot.targetCommitSHA {
            problems.append(.targetChanged(to: draft.targetCommitish))
        }
        let tagSHA = try await remote.tagCommitSHA(of: repository, tag: snapshot.tagName)
        if let tagSHA, tagSHA != snapshot.targetCommitSHA { problems.append(.tagExistsElsewhere(commitSHA: tagSHA)) }
        let releases = try await remote.releases(of: repository).items
        if releases.contains(where: { $0.tagName == snapshot.tagName && !$0.isDraft && $0.id != draft.id }) {
            problems.append(.tagAlreadyReleased)
        }
        return PublishPreview(
            snapshot: snapshot, draft: draft, repository: repository, existingTagCommitSHA: tagSHA, problems: problems)
    }

    /// Publishes the draft the user confirmed, after reading GitHub again: it must still be exactly the confirmed
    /// draft, with nothing blocking it. The request is sent once. Returns the verified outcome, normally
    /// `.published`; if GitHub deleted or published the draft meanwhile, records that instead.
    public func publishDraft(_ plan: ReleasePlan, confirmed: PublishPreview) async throws -> ReconcileOutcome {
        guard let current = try await publishPreview(plan) else { return try await reconcile(plan) }
        guard confirmed.confirms(current) else { throw ReleaseWorkflowError.reviewOutdated }
        if let problem = current.problemMessages.first { throw ReleaseWorkflowError.cannotPublish(problem) }

        switch await remote.publishRelease(in: current.repository, id: current.draft.id) {
        case .published(let release):
            // GitHub creates the tag as it publishes; give it a moment to be readable before verifying it.
            var waits = 0
            while waits < 2, try await remote.tagCommitSHA(of: current.repository, tag: release.tagName) == nil {
                waits += 1
                try await Task.sleep(for: tagWait)
            }
            return try await verifyPublication(
                try await currentPlan(plan.id, projectID: plan.projectID), snapshot: current.snapshot,
                repository: current.repository, release: release)
        case .rejected(let error):
            throw error
        case .unknown:
            throw ReleaseWorkflowError.publishOutcomeUnknown
        }
    }

    // MARK: Reconciling

    /// Reads GitHub and moves the plan to match it: links an unconfirmed draft, detects deletion, and verifies
    /// publication (the published tag must point at the reviewed commit).
    public func reconcile(_ plan: ReleasePlan) async throws -> ReconcileOutcome {
        let plan = try await currentPlan(plan.id, projectID: plan.projectID)
        let open = try await snapshots.snapshots(projectID: plan.projectID)
            .filter { $0.releasePlanID == plan.id && $0.state.isOpen }
            .max { $0.snapshotCreatedAt < $1.snapshotCreatedAt }

        switch (plan.status, open?.state) {
        case (.reconciliationNeeded, .pending?):
            return try await resolvePending(plan, snapshot: open!)
        case (.draftCreated, .draftCreated?), (.reconciliationNeeded, .draftCreated?):
            return try await verifyPublication(plan, snapshot: open!)
        case (.reconciliationNeeded, nil):
            // A status without a snapshot (for example from a restored backup): nothing was requested.
            try await snapshots.record(
                ReleaseRecord(
                    planID: plan.id, expectedStatus: .reconciliationNeeded, newStatus: .planned, operation: .none,
                    date: now()))
            return ReconcileOutcome(.noDraftFound)
        case (.planned, _):
            guard let connection = try await connection(of: plan), let tag = plan.tagName else {
                return ReconcileOutcome(.nothingToCheck)
            }
            let repository = try await remote.repository(id: connection.githubRepositoryID)
            let releases = try await remote.releases(of: repository).items
            if let published = releases.first(where: { $0.tagName == tag && !$0.isDraft }) {
                return ReconcileOutcome(.publishedExternally(published))
            }
            return ReconcileOutcome(.nothingToCheck)
        default:
            return ReconcileOutcome(.nothingToCheck, snapshot: open)
        }
    }

    /// After an unconfirmed create: finds the draft by tag and target commit, or concludes none was created.
    private func resolvePending(_ plan: ReleasePlan, snapshot: ReleaseSnapshot) async throws -> ReconcileOutcome {
        let repository = try await remote.repository(id: snapshot.githubRepositoryID)
        let (releases, truncated) = try await remote.releases(of: repository)
        let matches = releases.filter {
            $0.tagName == snapshot.tagName && $0.targetCommitish == snapshot.targetCommitSHA
        }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }

        guard let linked = matches.first else {
            guard !truncated else {
                throw ReleaseWorkflowError.cannotVerify("the repository has more releases than Relvora can list.")
            }
            try await snapshots.record(
                ReleaseRecord(
                    planID: plan.id, expectedStatus: .reconciliationNeeded, newStatus: .planned,
                    operation: .discardPending(snapshotID: snapshot.id), date: now()))
            return ReconcileOutcome(.noDraftFound)
        }

        let transition = SnapshotTransition.draftConfirmed(releaseID: linked.id, url: linked.htmlURL)
        let date = now()
        try await snapshots.record(
            ReleaseRecord(
                planID: plan.id, expectedStatus: .reconciliationNeeded, newStatus: .draftCreated,
                operation: .transition(snapshotID: snapshot.id, transition), date: date))
        let confirmed = snapshot.applying(transition, at: date)!
        var drafted = plan
        drafted.status = .draftCreated
        let duplicates = matches.dropFirst().filter(\.isDraft)
        if linked.isDraft {
            return ReconcileOutcome(.draftLinked, snapshot: confirmed, duplicateDrafts: Array(duplicates))
        }
        let outcome = try await verifyPublication(drafted, snapshot: confirmed, repository: repository, release: linked)
        return ReconcileOutcome(
            outcome.kind, snapshot: outcome.snapshot, duplicateDrafts: Array(duplicates), notes: outcome.notes)
    }

    private func verifyPublication(
        _ plan: ReleasePlan, snapshot: ReleaseSnapshot, repository: GitHubRepository? = nil,
        release: RemoteRelease? = nil
    ) async throws -> ReconcileOutcome {
        let repository = try await resolve(repository, id: snapshot.githubRepositoryID)
        guard let release = try await resolve(release, repository: repository, id: snapshot.githubReleaseID) else {
            let date = now()
            try await snapshots.record(
                ReleaseRecord(
                    planID: plan.id, expectedStatus: plan.status, newStatus: .planned,
                    operation: .transition(snapshotID: snapshot.id, .abandoned), date: date))
            return ReconcileOutcome(.draftDeleted, snapshot: snapshot.applying(.abandoned, at: date))
        }

        if release.isDraft {
            var notes: [String] = []
            if release.tagName != snapshot.tagName {
                notes.append("On GitHub, the draft’s tag was changed to \(release.tagName).")
            }
            if release.targetCommitish != snapshot.targetCommitSHA {
                notes.append("On GitHub, the draft’s target was changed to \(release.targetCommitish).")
            }
            if plan.status != .draftCreated {
                try await snapshots.record(
                    ReleaseRecord(
                        planID: plan.id, expectedStatus: plan.status, newStatus: .draftCreated, operation: .none,
                        date: now()))
            }
            return ReconcileOutcome(.stillDraft, snapshot: snapshot, notes: notes)
        }

        let tagSHA = try await remote.tagCommitSHA(of: repository, tag: release.tagName)
        guard release.tagName == snapshot.tagName, let tagSHA, tagSHA == snapshot.targetCommitSHA else {
            if plan.status != .reconciliationNeeded {
                try await snapshots.record(
                    ReleaseRecord(
                        planID: plan.id, expectedStatus: plan.status, newStatus: .reconciliationNeeded,
                        operation: .none, date: now()))
            }
            let mismatch = PublicationMismatch(
                expectedTag: snapshot.tagName, publishedTag: release.tagName,
                expectedCommitSHA: snapshot.targetCommitSHA, publishedCommitSHA: tagSHA)
            return ReconcileOutcome(.publicationMismatch(mismatch), snapshot: snapshot)
        }
        return ReconcileOutcome(
            .published,
            snapshot: try await recordPublication(plan, snapshot: snapshot, release: release, tagSHA: tagSHA))
    }

    /// Records a publication whose tag or commit differs from what was reviewed, after the user accepted it.
    @discardableResult
    public func acceptPublishedRelease(_ plan: ReleasePlan) async throws -> ReleaseSnapshot {
        let plan = try await currentPlan(plan.id, projectID: plan.projectID)
        guard plan.status == .reconciliationNeeded,
            let snapshot = try await snapshots.snapshots(projectID: plan.projectID)
                .first(where: { $0.releasePlanID == plan.id && $0.state == .draftCreated })
        else { throw ReleaseWorkflowError.wrongState(plan.status) }
        let repository = try await remote.repository(id: snapshot.githubRepositoryID)
        guard let id = snapshot.githubReleaseID, let release = try await remote.release(of: repository, id: id),
            !release.isDraft
        else { throw ReleaseWorkflowError.cannotVerify("the release isn’t published on GitHub.") }
        guard let tagSHA = try await remote.tagCommitSHA(of: repository, tag: release.tagName) else {
            throw ReleaseWorkflowError.cannotVerify("the tag \(release.tagName) doesn’t exist on GitHub.")
        }
        return try await recordPublication(plan, snapshot: snapshot, release: release, tagSHA: tagSHA)
    }

    private func recordPublication(
        _ plan: ReleasePlan, snapshot: ReleaseSnapshot, release: RemoteRelease, tagSHA: String
    ) async throws -> ReleaseSnapshot {
        let date = now()
        let publishedAt = release.publishedAt ?? date
        let transition = SnapshotTransition.published(
            at: publishedAt, url: release.htmlURL, notes: release.body, tagName: release.tagName, commitSHA: tagSHA)
        try await snapshots.record(
            ReleaseRecord(
                planID: plan.id, expectedStatus: plan.status, newStatus: .published, releasedAt: publishedAt,
                operation: .transition(snapshotID: snapshot.id, transition), date: date))
        return snapshot.applying(transition, at: date)!
    }

    // MARK: Releases published outside Relvora

    /// Records a release that was created and published on GitHub for the plan's tag. The tasks are frozen now;
    /// the notes, tag, and commit are GitHub's.
    @discardableResult
    public func recordPublishedRelease(_ plan: ReleasePlan) async throws -> ReleaseSnapshot {
        let plan = try await currentPlan(plan.id, projectID: plan.projectID)
        guard plan.status == .planned else { throw ReleaseWorkflowError.wrongState(plan.status) }
        guard let connection = try await connection(of: plan) else { throw ReleaseWorkflowError.repositoryNotConnected }
        guard let tag = plan.tagName else { throw ReleaseWorkflowError.notReady("the plan has no tag.") }
        let repository = try await remote.repository(id: connection.githubRepositoryID)
        guard
            let release = try await remote.releases(of: repository).items.first(where: {
                $0.tagName == tag && !$0.isDraft
            })
        else { throw ReleaseWorkflowError.noPublishedRelease(tag: tag) }
        guard let tagSHA = try await remote.tagCommitSHA(of: repository, tag: tag) else {
            throw ReleaseWorkflowError.cannotVerify("the tag \(tag) doesn’t exist on GitHub.")
        }
        let publishedAt = release.publishedAt ?? now()
        let snapshot = ReleaseSnapshot(
            projectID: plan.projectID,
            releasePlanID: plan.id,
            origin: .external,
            version: plan.version,
            title: plan.title,
            releaseName: release.name ?? tag,
            tagName: tag,
            targetCommitSHA: tagSHA,
            targetBranch: plan.targetBranch,
            isPrerelease: release.isPrerelease,
            releaseNotesMarkdown: release.body ?? "",
            tasks: try await frozenTasks(of: plan),
            changes: nil,
            checklist: ReleaseChecklist.snapshot(try await steps.steps(projectID: plan.projectID), plan: plan),
            githubRepositoryID: repository.id,
            repositoryFullName: repository.fullName,
            repositoryURL: repository.htmlURL,
            snapshotCreatedAt: now(),
            state: .published,
            githubReleaseID: release.id,
            githubReleaseURL: release.htmlURL,
            publishedAt: publishedAt,
            publishedCommitSHA: tagSHA
        )
        try await snapshots.record(
            ReleaseRecord(
                planID: plan.id, expectedStatus: .planned, newStatus: .published, releasedAt: publishedAt,
                targetCommitSHA: tagSHA, operation: .insert(snapshot), date: now()))
        return snapshot
    }

    // MARK: Helpers

    private func currentPlan(_ id: UUID, projectID: UUID) async throws -> ReleasePlan {
        guard let plan = try await plans.plans(projectID: projectID).first(where: { $0.id == id }) else {
            throw PersistenceError.notFound(entity: "release plan", id: id)
        }
        return plan
    }

    private func connection(of plan: ReleasePlan) async throws -> RepositoryConnection? {
        guard let id = plan.repositoryConnectionID else { return nil }
        return try await connections.connections(projectID: plan.projectID).first { $0.id == id }
    }

    private func frozenTasks(of plan: ReleasePlan) async throws -> [TaskSnapshot] {
        let columns = Dictionary(
            try await board.columns(projectID: plan.projectID).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }
        )
        return try await board.tasks(projectID: plan.projectID)
            .filter { $0.releasePlanID == plan.id }
            .map { TaskSnapshot($0, columnName: columns[$0.columnID]) }
    }

    private func resolve(_ repository: GitHubRepository?, id: Int64) async throws -> GitHubRepository {
        if let repository { return repository }
        return try await remote.repository(id: id)
    }

    private func resolve(_ release: RemoteRelease?, repository: GitHubRepository, id: Int64?) async throws
        -> RemoteRelease?
    {
        if let release { return release }
        guard let id else { throw ReleaseWorkflowError.cannotVerify("the draft’s GitHub ID is missing.") }
        return try await remote.release(of: repository, id: id)
    }
}
