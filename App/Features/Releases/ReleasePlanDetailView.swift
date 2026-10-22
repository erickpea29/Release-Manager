import RelvoraCore
import SwiftUI

/// One release plan: preparation while it is planned, then its GitHub draft and publication.
struct ReleasePlanDetailView: View {
    @Environment(AppModel.self) private var app
    @Bindable var release: ReleaseModel
    @State private var isConfirmingRecord = false
    @State private var isConfirmingAccept = false

    var body: some View {
        if let plan = release.plan {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(plan)
                    if let notice = release.notice {
                        NoticeBanner(notice: notice) { release.notice = nil }
                    }
                    if let message = release.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    content(plan)
                    earlierDrafts
                }
                .padding(Spacing.l)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: isReviewing) {
                if let review = release.review, let check = release.check {
                    CreateDraftSheet(release: release, review: review, check: check)
                }
            }
            .confirmationDialog(
                "Record the published release?", isPresented: $isConfirmingRecord, titleVisibility: .visible
            ) {
                Button("Record Release") { Task { await release.recordPublishedRelease() } }
            } message: {
                Text(
                    "Relvora saves GitHub’s notes, tag, and commit for \(plan.tagName ?? plan.version), with this "
                        + "plan’s tasks as they are now, and marks the plan published.")
            }
            .confirmationDialog(
                "Record as published?", isPresented: $isConfirmingAccept, titleVisibility: .visible
            ) {
                Button("Record as Published") { Task { await release.acceptPublishedRelease() } }
            } message: {
                Text(
                    "The published release differs from what you reviewed. History keeps both: the reviewed tag "
                        + "and commit, and what GitHub published.")
            }
            .task(id: plan.status) { await onAppear(plan) }
        }
    }

    private var isReviewing: Binding<Bool> {
        Binding(get: { release.review != nil }, set: { if !$0 { release.review = nil } })
    }

    /// Reads only: loads target choices, or checks a draft's publication.
    private func onAppear(_ plan: ReleasePlan) async {
        #if DEBUG
            // Its own task: this view task is cancelled whenever the plan's status changes.
            if let scenario = app.options.demoScenario.flatMap(DemoScenario.init) {
                let release = release
                Task { await scenario.run(on: release, app: app) }
            }
        #endif
        switch plan.status {
        case .planned: await release.loadTargets()
        case .draftCreated, .reconciliationNeeded:
            // A pending create is resolved only when the user asks, so a slow request can't race the check.
            if release.openSnapshot?.state == .draftCreated { await release.reconcile(quiet: true) }
        default: break
        }
    }

    private func header(_ plan: ReleasePlan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(plan.version)
                        .font(.title.bold().monospaced())
                        .textSelection(.enabled)
                    StatusBadge(status: plan.status)
                }
                if let title = plan.title {
                    Text(title).font(.title3).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if ReleasePlanRules.isEditable(plan) {
                Button("Edit Plan…") { release.workspace.planEditor = .edit(plan) }
            }
        }
    }

    @ViewBuilder
    private func content(_ plan: ReleasePlan) -> some View {
        switch plan.status {
        case .planned:
            if release.workspace.workflow == nil {
                Label(
                    "This build has no GitHub App configured, so drafts can’t be created.", systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }
            ReleaseTargetSection(release: release)
            ReleaseTasksSection(release: release)
            ReleaseNotesEditor(release: release)
            checkSection
        case .draftCreated:
            draftPanel
            if let snapshot = release.openSnapshot { SnapshotDetailView(snapshot: snapshot) }
        case .reconciliationNeeded:
            reconciliationPanel
            if let snapshot = release.openSnapshot { SnapshotDetailView(snapshot: snapshot) }
        case .published:
            publishedPanel
            if let snapshot = release.snapshots.last(where: { $0.state == .published }) {
                SnapshotDetailView(snapshot: snapshot)
            }
        case .cancelled:
            Label("This plan was cancelled. It is kept as a record.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Planned

    private var checkSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionTitle("Check and Create Draft", detail: "Relvora only creates drafts. You publish on GitHub.")
                Spacer()
                if release.isChecking { ProgressView().controlSize(.small) }
                Button("Check on GitHub", systemImage: "checklist") { Task { await release.runCheck() } }
                    .disabled(release.isChecking || !app.github.isConnected || release.workspace.workflow == nil)
            }
            let issues = release.check?.issues ?? release.localIssues
            if release.check == nil {
                Text("Not checked on GitHub yet. Existing tags and releases are checked before the draft is created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let checkedAt = release.check?.checkedAt {
                Text("Checked on GitHub \(checkedAt.formatted(.relative(presentation: .named))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if issues.isEmpty {
                Label("Ready for a draft.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(issues) { IssueRow(issue: $0) }
            if release.check?.publishedRelease != nil {
                Button("Record Published Release…") { isConfirmingRecord = true }
                    .disabled(release.isWorking)
            }
            HStack {
                if !app.github.isConnected && app.github.status != .unavailable {
                    Text("Connect GitHub in Settings to create drafts.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Create GitHub Draft…") { Task { await createDraft() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartDraft)
            }
        }
        .panel()
    }

    private var canStartDraft: Bool {
        app.github.isConnected && release.workspace.workflow != nil && !release.isChecking && !release.isWorking
            && !release.localIssues.contains { $0.severity == .blocking }
    }

    /// Checks GitHub again, then opens the confirmation with exactly what will be sent.
    private func createDraft() async {
        await release.runCheck()
        guard let check = release.check, check.isRemote, check.blockingIssues.isEmpty else { return }
        await release.beginReview()
    }

    // MARK: After the draft

    private var draftPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Draft on GitHub", systemImage: "doc.badge.clock")
                .font(.headline)
                .foregroundStyle(.blue)
            if let snapshot = release.openSnapshot {
                Text(
                    "Review and publish the draft on GitHub. Relvora records the release once GitHub shows it "
                        + "published and the tag \(snapshot.tagName) points at \(snapshot.targetCommitSHA.prefix(7))."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            actionRow(checkTitle: "Check Publication")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder
    private var reconciliationPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Needs reconciliation", systemImage: ReleasePlanStatus.reconciliationNeeded.symbol)
                .font(.headline)
                .foregroundStyle(.orange)
            if release.openSnapshot?.state == .pending {
                Text(
                    "GitHub didn’t confirm whether the draft was created. Relvora reads GitHub before anything is "
                        + "created again, so no duplicate is made."
                )
                .fixedSize(horizontal: false, vertical: true)
            } else if let mismatch = release.mismatch {
                mismatchDetails(mismatch)
            } else {
                Text("The release on GitHub doesn’t match what was reviewed. Check GitHub to see the difference.")
            }
            actionRow(checkTitle: "Check GitHub")
            if release.mismatch != nil {
                Button("Record as Published…") { isConfirmingAccept = true }
                    .disabled(release.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func mismatchDetails(_ mismatch: PublicationMismatch) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Published on GitHub, but not as reviewed:")
            Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: 2) {
                FactRow(label: "Reviewed") {
                    Text("\(mismatch.expectedTag) at \(mismatch.expectedCommitSHA.prefix(7))").font(
                        .callout.monospaced())
                }
                FactRow(label: "Published") {
                    Text(
                        "\(mismatch.publishedTag) at \(mismatch.publishedCommitSHA.map { String($0.prefix(7)) } ?? "a missing tag")"
                    )
                    .font(.callout.monospaced())
                }
            }
            Text("Check the release on GitHub. If it is right, record it as published.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actionRow(checkTitle: String) -> some View {
        HStack(spacing: Spacing.m) {
            if let url = release.openSnapshot?.githubReleaseURL {
                Link(destination: url) { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
            }
            Spacer()
            if release.isWorking { ProgressView().controlSize(.small) }
            Button(checkTitle, systemImage: "arrow.triangle.2.circlepath") { Task { await release.reconcile() } }
                .disabled(release.isWorking || !app.github.isConnected)
        }
    }

    private var publishedPanel: some View {
        let snapshot = release.snapshots.last { $0.state == .published }
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Published", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let snapshot, let date = snapshot.publishedAt {
                // Two lines: a localized time can end in a period ("12:17 a.m."), so no sentence follows it.
                Text("Published on GitHub on \(date.formatted(date: .abbreviated, time: .shortened))")
                Text("Verified: \(snapshot.effectiveTagName) points at \(snapshot.effectiveCommitSHA.prefix(7)).")
                    .foregroundStyle(.secondary)
            }
            if let snapshot {
                Button("Show in Release History") { app.showInHistory(snapshot.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    @ViewBuilder
    private var earlierDrafts: some View {
        let abandoned = release.snapshots.filter { $0.state == .abandoned }
        if !abandoned.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Earlier Drafts").font(.headline)
                ForEach(abandoned) { snapshot in
                    HStack {
                        SnapshotStateBadge(state: snapshot.state)
                        Text("Requested \(snapshot.snapshotCreatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in History") { app.showInHistory(snapshot.id) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

// MARK: - Sections

struct SectionTitle: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct IssueRow: View {
    let issue: ReleaseIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: issue.severity.symbol)
                .foregroundStyle(issue.severity.tint)
                .accessibilityLabel(label)
            Text(issue.message)
                .fixedSize(horizontal: false, vertical: true)
            if let url {
                Link("Open", destination: url).font(.callout)
            }
        }
    }

    private var label: String {
        switch issue.severity {
        case .blocking: "Must be fixed"
        case .warning: "Warning"
        case .note: "Note"
        }
    }

    private var url: URL? {
        switch issue.kind {
        case .releasePublished(_, let url), .draftExists(_, let url): url
        default: nil
        }
    }
}

struct NoticeBanner: View {
    let notice: ReleaseNotice
    let dismiss: () -> Void

    private var tint: Color {
        switch notice.tone {
        case .success: .green
        case .info: .blue
        case .warning: .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: notice.tone == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(notice.title).font(.headline)
                ForEach(notice.details, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: Spacing.m) {
                    ForEach(notice.links, id: \.self) { link in Link(link.title, destination: link.url) }
                }
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(Spacing.s)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.card))
    }
}

/// Repository, branch, commit, tag, and compare base.
struct ReleaseTargetSection: View {
    @Environment(AppModel.self) private var app
    let release: ReleaseModel
    @State private var tagText = ""
    @State private var shaText = ""
    @State private var isEnteringSHA = false
    @FocusState private var tagFocused: Bool

    var body: some View {
        if let plan = release.plan {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    SectionTitle("Target", detail: "The exact commit and tag GitHub will release.")
                    Spacer()
                    if release.isLoadingTargets { ProgressView().controlSize(.small) }
                }
                if release.workspace.connections.isEmpty {
                    Label("Connect a repository in this project’s GitHub tab first.", systemImage: "link")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                        FactRow(label: "Repository") { repositoryPicker(plan) }
                        if release.connection != nil {
                            FactRow(label: "Branch") { branchPicker(plan) }
                            FactRow(label: "Commit") { commitPicker(plan) }
                            FactRow(label: "Tag") { tagField(plan) }
                            FactRow(label: "Notes compare from") { basePicker(plan) }
                        }
                    }
                }
                if let error = release.targetError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .panel()
            .onAppear { tagText = plan.tagName ?? "" }
            .onChange(of: plan.tagName) { _, tag in if !tagFocused { tagText = tag ?? "" } }
            .onChange(of: tagFocused) { _, focused in if !focused { saveTag() } }
        }
    }

    private func repositoryPicker(_ plan: ReleasePlan) -> some View {
        Picker(
            "Repository",
            selection: Binding(
                get: { plan.repositoryConnectionID },
                set: { id in Task { await release.setRepository(id) } })
        ) {
            Text("Choose…").tag(UUID?.none)
            ForEach(release.workspace.connections) { Text($0.fullName).tag(UUID?.some($0.id)) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func branchPicker(_ plan: ReleasePlan) -> some View {
        let names = release.branches.map(\.name)
        if names.isEmpty {
            Text(plan.targetBranch ?? "Loading branches…")
                .foregroundStyle(plan.targetBranch == nil ? .secondary : .primary)
        } else {
            Picker(
                "Branch",
                selection: Binding(
                    get: { plan.targetBranch ?? "" },
                    set: { branch in Task { await release.setBranch(branch) } })
            ) {
                if plan.targetBranch == nil { Text("Choose…").tag("") }
                ForEach(names, id: \.self) { Text($0).tag($0) }
                if let current = plan.targetBranch, !names.contains(current) { Text(current).tag(current) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func commitPicker(_ plan: ReleasePlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
                Picker(
                    "Commit",
                    selection: Binding(
                        get: { plan.targetCommitSHA ?? "" },
                        set: { sha in Task { await release.setTargetCommit(sha.isEmpty ? nil : sha) } })
                ) {
                    Text("Choose a commit…").tag("")
                    ForEach(Array(release.commits.enumerated()), id: \.element.sha) { index, commit in
                        Text("\(commit.shortSHA)  \(commit.summary)\(index == 0 ? "  (latest)" : "")")
                            .tag(commit.sha)
                    }
                    if let sha = plan.targetCommitSHA, release.targetCommit == nil {
                        Text("\(sha.prefix(7))  (not among the latest commits)").tag(sha)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 420)
                Button("Other…") { isEnteringSHA = true }
                    .popover(isPresented: $isEnteringSHA) { shaPopover }
            }
            if let sha = plan.targetCommitSHA {
                Text(sha)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let commit = release.targetCommit {
                    HStack(spacing: Spacing.xs) {
                        Text(commit.summary).lineLimit(1)
                        if let author = commit.authorLogin.map({ "@\($0)" }) ?? commit.authorName {
                            Text("· \(author)")
                        }
                        if let date = commit.date { Text("· \(date.formatted(.relative(presentation: .named)))") }
                        Link(destination: commit.htmlURL) { Image(systemName: "arrow.up.right.square") }
                            .help("Open commit on GitHub")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shaPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Use a specific commit").font(.headline)
            TextField("Commit SHA", text: $shaText, prompt: Text("abc1234 or a full SHA"))
                .font(.body.monospaced())
                .frame(width: 320)
                .onSubmit(useSHA)
            HStack {
                Spacer()
                Button("Use Commit", action: useSHA)
                    .keyboardShortcut(.defaultAction)
                    .disabled(shaText.isBlank)
            }
        }
        .padding(Spacing.m)
    }

    private func useSHA() {
        let ref = shaText.trimmingCharacters(in: .whitespaces)
        isEnteringSHA = false
        shaText = ""
        Task { await release.useCommit(ref: ref) }
    }

    private func tagField(_ plan: ReleasePlan) -> some View {
        HStack(spacing: Spacing.s) {
            TextField("Tag", text: $tagText, prompt: Text(plan.suggestedTagName))
                .font(.body.monospaced())
                .frame(maxWidth: 220)
                .focused($tagFocused)
                .onSubmit(saveTag)
            if plan.tagName != plan.suggestedTagName {
                Button("Use \(plan.suggestedTagName)") {
                    tagText = plan.suggestedTagName
                    saveTag()
                }
                .buttonStyle(.link)
            }
            Text("Created by GitHub when you publish.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveTag() {
        let tag = tagText.trimmingCharacters(in: .whitespaces)
        guard tag != (release.plan?.tagName ?? "") else { return }
        Task { await release.setTagName(tag) }
    }

    private func basePicker(_ plan: ReleasePlan) -> some View {
        let tags = release.cachedSnapshot?.tags.map(\.name) ?? []
        return Picker(
            "Compare from",
            selection: Binding(
                get: { plan.compareBaseTag ?? "" },
                set: { tag in Task { await release.setCompareBase(tag.isEmpty ? nil : tag) } })
        ) {
            Text(release.effectiveBaseTag.map { "Latest release (\($0))" } ?? "No earlier release").tag("")
            ForEach(tags, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The plan's tasks and their completion.
struct ReleaseTasksSection: View {
    let release: ReleaseModel

    var body: some View {
        let tasks = release.tasks
        let done = tasks.filter { $0.completedAt != nil }.count
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionTitle(
                "Tasks",
                detail: tasks.isEmpty
                    ? "Assign tasks to this release from the task editor."
                    : "\(done) of \(tasks.count) complete. Releasing never changes tasks.")
            ForEach(tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: task.completedAt != nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.completedAt != nil ? .green : .secondary)
                        .accessibilityLabel(task.completedAt != nil ? "Complete" : "Not complete")
                    Image(systemName: task.type.symbol)
                        .foregroundStyle(.secondary)
                        .help(task.type.title)
                    Text(task.title)
                    Spacer()
                    Text(release.workspace.columnName(task.columnID) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .panel()
    }
}
