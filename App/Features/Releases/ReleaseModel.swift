import Foundation
import GitHubIntegration
import Observation
import RelvoraCore

/// A message about the last GitHub step, shown in the release view until the next one.
struct ReleaseNotice: Equatable {
    enum Tone { case success, info, warning }

    struct Link: Hashable {
        let title: String
        let url: URL
    }

    let tone: Tone
    let title: String
    var details: [String] = []
    var links: [Link] = []
}

/// Preparation and GitHub workflow state for one release plan. Every GitHub write goes through `ReleaseWorkflow`.
@Observable
final class ReleaseModel {
    let planID: UUID
    let workspace: WorkspaceModel
    let github: GitHubModel
    let preferences: Preferences

    // Target choices, read from GitHub.
    private(set) var branches: [RemoteBranch] = []
    private(set) var commits: [RemoteCommit] = []
    private(set) var commitsBranch: String?
    private(set) var isLoadingTargets = false
    private(set) var targetError: String?
    private var targetsGeneration = 0
    private var commitsGeneration = 0

    // Changes behind the notes.
    private(set) var changes: UnreleasedChanges?
    private(set) var changesKey: String?
    private(set) var changeNotes: [String] = []
    private(set) var isLoadingChanges = false
    private(set) var changesError: String?
    var changelogOptions = ChangelogOptions()
    /// The notes as typed. Saved shortly after typing stops, and before a review.
    var notesText = "" {
        didSet { if notesText != oldValue { scheduleNotesSave() } }
    }
    private var notesSave: Task<Void, Never>?

    // Checks and workflow steps.
    private(set) var check: ReleaseCheck?
    private(set) var isChecking = false
    private(set) var isWorking = false
    private(set) var mismatch: PublicationMismatch?
    var notice: ReleaseNotice?
    var errorMessage: String?
    /// Presents the confirmation sheet.
    var review: ReleaseReview?
    /// The draft as GitHub has it, while the user confirms publishing it.
    var publishPreview: PublishPreview?

    init(planID: UUID, workspace: WorkspaceModel, github: GitHubModel, preferences: Preferences) {
        self.planID = planID
        self.workspace = workspace
        self.github = github
        self.preferences = preferences
        notesText = workspace.plan(planID)?.changelogMarkdown ?? ""
    }

    var plan: ReleasePlan? { workspace.plan(planID) }
    var connection: RepositoryConnection? { plan.flatMap(workspace.connection) }
    var tasks: [ProjectTask] { plan.map(workspace.tasks) ?? [] }
    var openSnapshot: ReleaseSnapshot? { plan.flatMap(workspace.openSnapshot) }
    var snapshots: [ReleaseSnapshot] { plan.map(workspace.snapshots) ?? [] }
    var cachedSnapshot: RepositorySnapshot? { connection.flatMap { github.snapshot(for: $0.githubRepositoryID) } }

    var localIssues: [ReleaseIssue] {
        guard let plan else { return [] }
        return ReleaseChecker.localIssues(
            plan: plan, tasks: tasks, connection: connection, steps: workspace.releaseSteps
        )
        .sorted { $0.severity < $1.severity }
    }

    /// The version the release's changes suggest, while the plan is being prepared: its completed tasks and, once
    /// loaded, GitHub's changes since the compare base.
    var versionSuggestion: VersionSuggestion? {
        guard let plan, ReleasePlanRules.isEditable(plan) else { return nil }
        if case .custom? = try? ReleaseVersion(parsing: plan.version) { return nil }
        var options = changelogOptions
        options.labelRules = ChangelogLabelRule.normalized(preferences.changelogLabelRules)
        let input = ChangelogInput(tasks: tasks, changes: currentChanges, tagName: plan.tagName, repositoryURL: nil)
        let released =
            [effectiveBaseTag].compactMap(\.self)
            + workspace.releasedVersions(cached: cachedSnapshot.map { [$0] } ?? [])
        return VersionSuggester.suggest(
            after: VersionSuggester.latestStable(released),
            changes: ChangelogGenerator.entries(input, options: options).map(\.category))
    }

    /// Ticks or unticks a release checklist step. The last GitHub check no longer describes the plan, so it is
    /// cleared and the current local findings show.
    func setStep(_ stepID: UUID, done: Bool) async {
        guard let plan else { return }
        await workspace.setStep(stepID, done: done, on: plan)
        check = nil
    }

    /// The project's checklist was edited: as for `setStep`, the last check is out of date.
    func checklistDidChange() {
        check = nil
    }

    /// Changes the plan's version, and its tag too when the tag simply followed the old version.
    func useVersion(_ version: SemanticVersion) async {
        await edit { plan in
            let followedVersion = plan.tagName == nil || plan.tagName == plan.suggestedTagName
            plan.version = version.description
            if followedVersion { plan.tagName = plan.suggestedTagName }
        }
    }

    /// The compare base the notes use: the plan's choice, else the latest release (as M03's sync chooses it).
    var effectiveBaseTag: String? {
        if let base = plan?.compareBaseTag { return base }
        guard let cached = cachedSnapshot else { return nil }
        return GitHubSyncService.baseTag(latestRelease: cached.latestPublishedRelease, tags: cached.tags)
    }

    /// The selected commit, when it is among the loaded ones.
    var targetCommit: RemoteCommit? { commits.first { $0.sha == plan?.targetCommitSHA } }

    private var currentChangesKey: String? {
        guard let connection, let sha = plan?.targetCommitSHA else { return nil }
        return "\(connection.githubRepositoryID) \(effectiveBaseTag ?? "-") \(sha)"
    }

    /// Loaded changes that match the current repository, base, and target commit.
    var currentChanges: UnreleasedChanges? { changesKey == currentChangesKey ? changes : nil }

    // MARK: Editing the target

    func setRepository(_ connectionID: UUID?) async {
        let connection = connectionID.flatMap { id in workspace.connections.first { $0.id == id } }
        await edit {
            $0.repositoryConnectionID = connectionID
            $0.targetBranch = connection?.defaultBranch ?? $0.targetBranch
            $0.targetCommitSHA = nil
            $0.compareBaseTag = nil
            if $0.tagName == nil { $0.tagName = $0.suggestedTagName }
        }
        branches = []
        commits = []
        await loadTargets()
    }

    func setBranch(_ branch: String) async {
        guard branch != plan?.targetBranch else { return }
        await edit {
            $0.targetBranch = branch
            $0.targetCommitSHA = nil
        }
        await loadCommits()
    }

    func setTargetCommit(_ sha: String?) async {
        await edit { $0.targetCommitSHA = sha }
    }

    /// Resolves a pasted SHA (short or full) on GitHub and selects it.
    func useCommit(ref: String) async {
        guard let connection else { return }
        do {
            let commit = try await github.commit(of: connection.githubRepositoryID, ref: ref)
            if !commits.contains(where: { $0.sha == commit.sha }) { commits.insert(commit, at: 0) }
            await setTargetCommit(commit.sha)
        } catch {
            targetError = AppAlert.message(for: error)
        }
    }

    func setTagName(_ tag: String) async {
        await edit { $0.tagName = tag }
    }

    func setCompareBase(_ tag: String?) async {
        await edit { $0.compareBaseTag = tag }
    }

    /// Saves typed notes now (before a review, or when the editor closes).
    func flushNotes() async {
        notesSave?.cancel()
        await saveNotes(notesText)
    }

    private func scheduleNotesSave() {
        notesSave?.cancel()
        notesSave = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await saveNotes(notesText)
        }
    }

    private func saveNotes(_ markdown: String) async {
        guard markdown != plan?.changelogMarkdown, plan?.status == .planned else { return }
        await edit { $0.changelogMarkdown = markdown }
    }

    private func edit(_ change: @escaping (inout ReleasePlan) -> Void) async {
        do {
            try await workspace.updatePlan(planID, change)
            errorMessage = nil
            check = nil
        } catch {
            errorMessage = AppAlert.message(for: error)
        }
    }

    // MARK: Reading GitHub

    /// Branches and the chosen branch's latest commits, for the target pickers. A newer load supersedes an older
    /// one: only the latest load's results are applied, so a slow load can't show another repository's commits.
    func loadTargets() async {
        targetsGeneration += 1
        let generation = targetsGeneration
        guard let connection, github.isConnected else { return }
        isLoadingTargets = true
        defer { if generation == targetsGeneration { isLoadingTargets = false } }
        // Tags and the latest release (the default compare base) come from the repository snapshot.
        if cachedSnapshot == nil, let remote = await github.refresh(repositoryID: connection.githubRepositoryID) {
            await workspace.recordSync(of: connection, remote: remote)
        }
        do {
            let loaded = try await github.branches(of: connection.githubRepositoryID)
            guard generation == targetsGeneration else { return }
            branches = loaded
            targetError = nil
        } catch {
            guard generation == targetsGeneration else { return }
            targetError = AppAlert.message(for: error)
        }
        await loadCommits()
    }

    /// The chosen branch's latest commits. Like `loadTargets`, only the latest load is applied.
    func loadCommits() async {
        commitsGeneration += 1
        let generation = commitsGeneration
        guard let connection, let branch = plan?.targetBranch, github.isConnected else { return }
        do {
            let loaded = try await github.commits(of: connection.githubRepositoryID, branch: branch)
            guard generation == commitsGeneration else { return }
            commits = loaded
            commitsBranch = branch
            targetError = nil
        } catch {
            guard generation == commitsGeneration else { return }
            commits = []
            targetError = AppAlert.message(for: error)
        }
    }

    /// Commits and merged pull requests from the base tag to the target commit.
    @discardableResult
    func loadChanges() async -> UnreleasedChanges? {
        if let current = currentChanges { return current }
        guard let connection, let sha = plan?.targetCommitSHA, let key = currentChangesKey else { return nil }
        isLoadingChanges = true
        defer { isLoadingChanges = false }
        do {
            let result = try await github.changes(
                of: connection.githubRepositoryID, base: effectiveBaseTag, head: sha, branch: plan?.targetBranch)
            changes = result.changes
            changeNotes = result.notes
            changesKey = key
            changesError = nil
            return result.changes
        } catch {
            changesError = AppAlert.message(for: error)
            return nil
        }
    }

    /// Release notes from completed tasks and, when available, GitHub's commits and pull requests.
    func generatedNotes() async -> String? {
        guard let plan else { return nil }
        let changes =
            (changelogOptions.includePullRequests || changelogOptions.includeCommits) ? await loadChanges() : nil
        let input = ChangelogInput(
            tasks: tasks, changes: changes, tagName: plan.tagName, repositoryURL: connection?.htmlURL)
        var options = changelogOptions
        options.labelRules = ChangelogLabelRule.normalized(preferences.changelogLabelRules)
        return ChangelogGenerator.markdown(input, options: options)
    }

    var notesWarnings: [String] {
        let input = ChangelogInput(
            tasks: tasks, changes: currentChanges, tagName: plan?.tagName, repositoryURL: connection?.htmlURL)
        return ChangelogGenerator.warnings(input, options: changelogOptions) + changeNotes
    }

    // MARK: Workflow

    /// Local and GitHub checks for the plan. Reads only.
    func runCheck() async {
        await flushNotes()
        guard let plan, let workflow = workspace.workflow else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            check = try await workflow.check(plan)
            errorMessage = nil
        } catch {
            github.noteError(error)
            errorMessage = AppAlert.message(for: error)
        }
    }

    /// Opens the confirmation sheet with exactly what will be sent.
    func beginReview() async {
        await flushNotes()
        guard let plan, let connection else { return }
        let changes = await loadChanges()
        review = ReleaseReview(plan: plan, connection: connection, changes: changes.map(ReleaseChangeSummary.init))
    }

    /// Creates the draft. Returns true when the sheet can close: on success, and on outcomes that need
    /// reconciliation (the plan view explains those).
    func createDraft(_ review: ReleaseReview) async -> Result<Void, any Error> {
        guard let workflow = workspace.workflow else { return .success(()) }
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = try await workflow.createDraft(review)
            await workspace.reloadReleases()
            notice = ReleaseNotice(
                tone: .success, title: "Draft created on GitHub",
                details: [
                    "Publish it here when it’s ready. If you publish it on GitHub instead, choose Check Publication."
                ],
                links: snapshot.githubReleaseURL.map { [.init(title: "Open Draft on GitHub", url: $0)] } ?? [])
            check = nil
            return .success(())
        } catch {
            github.noteError(error)
            await workspace.reloadReleases()
            return .failure(error)
        }
    }

    /// Reads the draft from GitHub and opens the publish confirmation, or records what happened to the draft if it
    /// was deleted or published on GitHub meanwhile.
    func beginPublish() async {
        guard let plan, let workflow = workspace.workflow, !isWorking else { return }
        isWorking = true
        do {
            let preview = try await workflow.publishPreview(plan)
            isWorking = false
            errorMessage = nil
            if let preview { publishPreview = preview } else { await reconcile() }
        } catch {
            isWorking = false
            github.noteError(error)
            errorMessage = AppAlert.message(for: error)
        }
    }

    /// Publishes the confirmed draft. Returns failure only for errors the sheet should show; an unknown outcome
    /// closes the sheet, and the plan view explains it.
    func publish(_ preview: PublishPreview) async -> Result<Void, any Error> {
        guard let plan, let workflow = workspace.workflow else { return .success(()) }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await workflow.publishDraft(plan, confirmed: preview)
            await workspace.reloadReleases()
            apply(outcome, quiet: false)
            errorMessage = nil
            return .success(())
        } catch ReleaseWorkflowError.publishOutcomeUnknown {
            errorMessage = AppAlert.message(for: ReleaseWorkflowError.publishOutcomeUnknown)
            return .success(())
        } catch {
            github.noteError(error)
            await workspace.reloadReleases()
            return .failure(error)
        }
    }

    /// Reads GitHub and updates the plan to match.
    func reconcile(quiet: Bool = false) async {
        guard let plan, let workflow = workspace.workflow, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await workflow.reconcile(plan)
            await workspace.reloadReleases()
            apply(outcome, quiet: quiet)
            errorMessage = nil
        } catch {
            github.noteError(error)
            if !quiet { errorMessage = AppAlert.message(for: error) }
        }
    }

    func recordPublishedRelease() async {
        await perform { workflow, plan in
            let snapshot = try await workflow.recordPublishedRelease(plan)
            self.notice = ReleaseNotice(
                tone: .success, title: "Recorded \(snapshot.tagName) from GitHub",
                details: ["Its notes and commit are GitHub’s; the tasks are as they are now."])
        }
    }

    func acceptPublishedRelease() async {
        await perform { workflow, plan in
            let snapshot = try await workflow.acceptPublishedRelease(plan)
            self.mismatch = nil
            self.notice = ReleaseNotice(
                tone: .success, title: "Recorded as published",
                details: [
                    "History shows the published tag \(snapshot.effectiveTagName) at "
                        + "\(snapshot.effectiveCommitSHA.prefix(7)), beside what was reviewed."
                ])
        }
    }

    private func perform(_ step: @escaping (ReleaseWorkflow, ReleasePlan) async throws -> Void) async {
        guard let plan, let workflow = workspace.workflow, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await step(workflow, plan)
            errorMessage = nil
        } catch {
            github.noteError(error)
            errorMessage = AppAlert.message(for: error)
        }
        check = nil
        await workspace.reloadReleases()
    }

    private func apply(_ outcome: ReconcileOutcome, quiet: Bool) {
        mismatch = nil
        var notice: ReleaseNotice?
        switch outcome.kind {
        case .noDraftFound:
            notice = ReleaseNotice(
                tone: .info, title: "GitHub has no draft from that request",
                details: ["Nothing was created, so you can create the draft again."])
        case .draftLinked:
            notice = ReleaseNotice(
                tone: .success, title: "Found the draft on GitHub and linked it",
                links: outcome.snapshot?.githubReleaseURL.map { [.init(title: "Open Draft on GitHub", url: $0)] } ?? [])
        case .stillDraft:
            if !quiet || !outcome.notes.isEmpty {
                notice = ReleaseNotice(
                    tone: outcome.notes.isEmpty ? .info : .warning, title: "Still a draft on GitHub",
                    details: outcome.notes)
            }
        case .published:
            let sha = outcome.snapshot.map { String($0.effectiveCommitSHA.prefix(7)) } ?? ""
            notice = ReleaseNotice(
                tone: .success, title: "Published on GitHub",
                details: ["Verified: \(outcome.snapshot?.effectiveTagName ?? "the tag") points at \(sha)."])
        case .publicationMismatch(let mismatch):
            // The reconciliation panel explains it; an earlier "draft created" notice would contradict it.
            self.mismatch = mismatch
            self.notice = nil
        case .draftDeleted:
            notice = ReleaseNotice(
                tone: .warning, title: "The draft was deleted on GitHub",
                details: ["It stays in Release History as deleted. You can create a new draft."])
        case .publishedExternally(let release):
            notice = ReleaseNotice(
                tone: .warning, title: "GitHub already has a published release for \(release.tagName)",
                details: ["Record it to keep it in Release History, or choose another version and tag."],
                links: [.init(title: "Open on GitHub", url: release.htmlURL)])
        case .nothingToCheck:
            if !quiet { notice = ReleaseNotice(tone: .info, title: "Nothing to check on GitHub") }
        }
        if !outcome.duplicateDrafts.isEmpty {
            let count = outcome.duplicateDrafts.count
            var duplicate = notice ?? ReleaseNotice(tone: .warning, title: "Duplicate drafts on GitHub")
            duplicate.details.append(
                "GitHub also has \(count) duplicate \(count == 1 ? "draft" : "drafts") for this tag. Delete "
                    + "\(count == 1 ? "it" : "them") on GitHub.")
            duplicate.links += outcome.duplicateDrafts.map {
                .init(title: "Duplicate draft #\($0.id)", url: $0.htmlURL)
            }
            notice = duplicate
        }
        if let notice { self.notice = notice }
    }
}
