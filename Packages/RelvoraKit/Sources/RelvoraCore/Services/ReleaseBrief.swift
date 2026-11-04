import Foundation

// The release brief (ADR 0025): a panel above a planned version that says where it stands, what's in it, what stands
// in its way, and what to do next. Relvora knows the facts; the on-device model, when there is one, only composes
// them: it writes the headline and summary, groups the tasks into themes, orders the sections, and picks the next
// step from the actions Relvora offers. Everything it returns is checked against the facts before it's shown.

// MARK: - Actions

/// Where a brief's action scrolls to in the plan.
public enum ReleaseBriefAnchor: String, Sendable, Hashable, CaseIterable {
    case pullRequests, target, tasks, notes, checklist, check
}

/// What a brief's button does. Each is something the plan view already offers; GitHub writes still go through their
/// own confirmation.
public enum ReleaseBriefAction: Sendable, Hashable {
    /// Selects this commit as the release's target.
    case useCommit(sha: String)
    case show(ReleaseBriefAnchor)
    case openURL(URL)
    /// Runs the GitHub check (reads only).
    case checkOnGitHub
    /// Checks GitHub again, then opens the draft confirmation.
    case createDraft
    case editPlan

    /// Titles differ from the plan's own buttons, so each label names one button.
    public var title: String {
        switch self {
        case .useCommit(let sha): "Use \(sha.prefix(7))"
        case .show(.pullRequests): "Go to Pull Requests"
        case .show(.target): "Go to Target"
        case .show(.tasks): "Go to Tasks"
        case .show(.notes): "Go to Notes"
        case .show(.checklist): "Go to Checklist"
        case .show(.check): "Go to Check"
        case .openURL: "View on GitHub"
        case .checkOnGitHub: "Check Now"
        case .createDraft: "Start the Draft…"
        case .editPlan: "Change Version…"
        }
    }

    public var symbol: String {
        switch self {
        case .useCommit: "checkmark.circle"
        case .show: "arrow.down.circle"
        case .openURL: "arrow.up.right.square"
        case .checkOnGitHub: "checklist"
        case .createDraft: "doc.badge.plus"
        case .editPlan: "pencil"
        }
    }
}

// MARK: - Facts

/// Something about the plan the brief points out, with the action that deals with it.
public struct ReleaseBriefAttention: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case issue(ReleaseIssue.Kind)
        case targetCIFailed(checks: String)
        case targetCIRunning
        /// A newer commit than the selected one passed CI.
        case newerPassingCommit(sha: String)
        case pullRequest(number: Int, title: String, readiness: MergeReadiness)
    }

    /// Stable across changes to the plan, so a brief written earlier still points at the same thing: `commit`,
    /// `tasks`, `ci`, `pr-15`…
    public let key: String
    public let kind: Kind
    public let severity: ReleaseIssue.Severity
    public let message: String
    public let action: ReleaseBriefAction?

    public var id: String { key }

    public init(
        key: String, kind: Kind, severity: ReleaseIssue.Severity, message: String, action: ReleaseBriefAction?
    ) {
        self.key = key
        self.kind = kind
        self.severity = severity
        self.message = message
        self.action = action
    }
}

/// Where the version stands, from the facts alone.
public enum ReleaseBriefVerdict: String, Sendable, Hashable {
    /// Something must be fixed before the draft.
    case blocked
    /// Nothing blocks the draft, but something deserves a look first, such as unfinished tasks or failing CI.
    case almostReady
    case ready

    public var title: String {
        switch self {
        case .blocked: "Not ready yet"
        case .almostReady: "Almost ready"
        case .ready: "Ready for a draft"
        }
    }
}

/// What Relvora knows about a planned version, for its brief. The brief never says more than this.
public struct ReleaseBriefFacts: Sendable, Equatable {
    public struct TaskFact: Sendable, Hashable, Identifiable {
        /// The model's reference: T1, T2…
        public let ref: String
        public let id: UUID
        public let title: String
        public let type: TaskType
        public let isDone: Bool
        public let column: String?

        public init(ref: String, id: UUID, title: String, type: TaskType, isDone: Bool, column: String?) {
            self.ref = ref
            self.id = id
            self.title = title
            self.type = type
            self.isDone = isDone
            self.column = column
        }
    }

    public let version: String
    public let title: String?
    public let plannedDate: Date?
    public let tasks: [TaskFact]
    /// Most severe first.
    public let attention: [ReleaseBriefAttention]
    public let checklistDone: Int
    public let checklistTotal: Int
    public let hasTargetCommit: Bool
    /// The selected commit's CI, once read.
    public let targetCI: CIStatus?
    /// Checked on GitHub since the plan last changed.
    public let isCheckedOnGitHub: Bool
    /// The first lines of the commits since the base, newest first, once GitHub's changes are read.
    public let commitSummaries: [String]
    /// The tag the changes start from: the last release.
    public let baseTag: String?

    public init(
        version: String, title: String?, plannedDate: Date?, tasks: [TaskFact], attention: [ReleaseBriefAttention],
        checklistDone: Int, checklistTotal: Int, hasTargetCommit: Bool, targetCI: CIStatus?, isCheckedOnGitHub: Bool,
        commitSummaries: [String] = [], baseTag: String? = nil
    ) {
        self.version = version
        self.title = title
        self.plannedDate = plannedDate
        self.tasks = tasks
        self.attention = attention
        self.checklistDone = checklistDone
        self.checklistTotal = checklistTotal
        self.hasTargetCommit = hasTargetCommit
        self.targetCI = targetCI
        self.isCheckedOnGitHub = isCheckedOnGitHub
        self.commitSummaries = commitSummaries
        self.baseTag = baseTag
    }

    public var doneCount: Int { tasks.filter(\.isDone).count }

    public var verdict: ReleaseBriefVerdict {
        if attention.contains(where: { $0.severity == .blocking }) { return .blocked }
        if attention.contains(where: { $0.severity == .warning }) { return .almostReady }
        return .ready
    }

    /// What a written brief is about. When it changes, the brief is written again; the counts and actions shown
    /// always come from the current facts.
    public var fingerprint: String {
        var lines = [version, title ?? ""]
        lines += tasks.map { "\($0.ref) \($0.type.rawValue) \($0.isDone) \($0.title)" }
        lines += attention.map { "\($0.key) \($0.severity.rawValue)" }
        lines.append("checklist \(checklistDone)/\(checklistTotal)")
        lines += commitSummaries.prefix(ReleaseBriefComposer.maximumCommits).map { "commit \($0)" }
        return lines.joined(separator: "\n")
    }

    /// The next steps the model may choose from: the attention keys with an action, and `draft` when nothing blocks
    /// it.
    public var nextStepKeys: [String] {
        var keys = attention.filter { $0.action != nil }.map(\.key)
        if verdict != .blocked { keys.append(ReleaseBriefComposer.draftKey) }
        return keys
    }
}

// MARK: - The brief

/// What the model composed, before it's checked against the facts. While it streams, any field may be missing.
public struct ReleaseBriefComposition: Sendable, Equatable {
    public struct Theme: Sendable, Equatable {
        public var title: String?
        public var symbol: String?
        public var taskRefs: [String]?

        public init(title: String? = nil, symbol: String? = nil, taskRefs: [String]? = nil) {
            self.title = title
            self.symbol = symbol
            self.taskRefs = taskRefs
        }
    }

    public var headline: String?
    public var summary: String?
    /// A title for what the commits do, like a pull request's: the release contents card's heading.
    public var changesTitle: String?
    /// Section names, in the order to show them: `themes`, `attention`, `progress`.
    public var layout: [String]?
    public var themes: [Theme]?
    /// Attention keys, most important first.
    public var attentionOrder: [String]?
    /// One of `ReleaseBriefFacts.nextStepKeys`.
    public var nextStep: String?
    public var nextStepReason: String?

    public init(
        headline: String? = nil, summary: String? = nil, changesTitle: String? = nil, layout: [String]? = nil,
        themes: [Theme]? = nil, attentionOrder: [String]? = nil, nextStep: String? = nil, nextStepReason: String? = nil
    ) {
        self.headline = headline
        self.summary = summary
        self.changesTitle = changesTitle
        self.layout = layout
        self.themes = themes
        self.attentionOrder = attentionOrder
        self.nextStep = nextStep
        self.nextStepReason = nextStepReason
    }
}

/// The brief as shown: the composition checked against the facts, or Relvora's standard brief when no model wrote one.
public struct ReleaseBrief: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Composed by Relvora's rules, without a model.
        case standard
        /// Composed by the on-device model; `isComplete` is false while it's still writing.
        case model(isComplete: Bool)
    }

    public enum Section: String, Sendable, Hashable, CaseIterable, Identifiable {
        case themes, attention, progress

        public var id: Self { self }
    }

    public struct Theme: Sendable, Hashable, Identifiable {
        public let title: String
        public let symbol: String
        public let tasks: [ReleaseBriefFacts.TaskFact]

        public var id: String { title }
    }

    public struct NextStep: Sendable, Hashable {
        public let action: ReleaseBriefAction
        public let reason: String
    }

    public let verdict: ReleaseBriefVerdict
    /// `nil` while the model hasn't written it yet.
    public let headline: String?
    public let summary: String?
    /// The model's title for the commits; `nil` without a model, when the card uses Relvora's own.
    public let changesTitle: String?
    public let nextStep: NextStep?
    /// Every section, in the order to show them.
    public let sections: [Section]
    public let themes: [Theme]
    public let attention: [ReleaseBriefAttention]
    public let source: Source
}

// MARK: - Composing

/// The brief's rules, as pure functions: the facts, the standard brief, the model's prompt, and checking what it wrote.
public enum ReleaseBriefComposer {
    /// The next-step key for creating the draft.
    public static let draftKey = "draft"
    /// What the prompt includes at most, to stay well inside the on-device model's context.
    public static let maximumTasks = 40
    public static let maximumPullRequests = 4
    public static let maximumCommits = 20
    static let maximumTitleLength = 90
    static let maximumThemes = 5

    /// The symbols a theme may use; anything else gets its tasks' type symbol.
    public static let themeSymbols: [String] = [
        "sparkles", "wand.and.stars", "ladybug", "doc.text", "wrench.and.screwdriver", "bolt", "lock.shield",
        "paintbrush", "arrow.triangle.branch", "bell", "gearshape", "person.2", "chart.bar", "tray.full",
        "shippingbox", "keyboard", "menubar.rectangle", "square.grid.2x2", "link", "magnifyingglass",
    ]

    // MARK: Facts

    /// Gathers the facts. `issues` are the last check's findings (local ones when not checked on GitHub);
    /// `pullRequests` are the open ones into the release's branch, with whether Relvora would merge them now.
    public static func facts(
        plan: ReleasePlan, tasks: [ProjectTask], columnNames: [UUID: String], issues: [ReleaseIssue],
        isCheckedOnGitHub: Bool, steps: [ReleaseStep], targetCI: CIStatus?, latestPassingSHA: String?,
        pullRequests: [(PullRequest, MergeReadiness)], changes: UnreleasedChanges? = nil
    ) -> ReleaseBriefFacts {
        let planTasks = tasks.filter { $0.releasePlanID == plan.id }
        let briefTasks = planTasks.enumerated().map { index, task in
            ReleaseBriefFacts.TaskFact(
                ref: "T\(index + 1)", id: task.id, title: task.title, type: task.type, isDone: task.completedAt != nil,
                column: columnNames[task.columnID])
        }
        let newerPassing = latestPassingSHA.flatMap { $0 == plan.targetCommitSHA ? nil : $0 }

        var attention = issues.map { attentionItem(for: $0, latestPassingSHA: newerPassing) }
        if plan.targetCommitSHA != nil {
            switch targetCI {
            case .failed?:
                attention.append(
                    ReleaseBriefAttention(
                        key: "ci", kind: .targetCIFailed(checks: targetCI?.failingChecks ?? ""), severity: .warning,
                        message: "CI failed on the selected commit: \(targetCI?.failingChecks ?? "a check").",
                        action: newerPassing.map { .useCommit(sha: $0) } ?? .show(.target)))
            case .running?:
                attention.append(
                    ReleaseBriefAttention(
                        key: "ci", kind: .targetCIRunning, severity: .note,
                        message: "CI is still running on the selected commit.", action: nil))
            case .passed?, .notReported?, nil:
                if let newerPassing {
                    attention.append(
                        ReleaseBriefAttention(
                            key: "newer-commit", kind: .newerPassingCommit(sha: newerPassing), severity: .note,
                            message: "A newer commit, \(newerPassing.prefix(7)), passed CI.",
                            action: .useCommit(sha: newerPassing)))
                }
            }
        }
        let pulls = pullRequests.filter { !$0.0.isDraft && $0.0.state == .open }.prefix(maximumPullRequests)
        for (pull, readiness) in pulls {
            let ready = readiness == .ready
            attention.append(
                ReleaseBriefAttention(
                    key: "pr-\(pull.number)",
                    kind: .pullRequest(number: pull.number, title: pull.title, readiness: readiness),
                    severity: readiness == .ciFailed || readiness == .conflicts ? .warning : .note,
                    message: ready
                        ? "#\(pull.number) “\(pull.title)” is ready to merge into \(pull.baseRef)."
                        : "#\(pull.number) “\(pull.title)”: \(readiness.summary).",
                    action: ready ? .show(.pullRequests) : .openURL(pull.htmlURL)))
        }

        // One item per key, the most severe; most severe first, otherwise in the order found.
        var seen = Set<String>()
        let unique =
            attention
            .enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
            .filter { seen.insert($0.key).inserted }

        let remaining = ReleaseChecklist.remaining(steps, plan: plan).count
        return ReleaseBriefFacts(
            version: plan.version, title: plan.title, plannedDate: plan.plannedDate, tasks: briefTasks,
            attention: unique, checklistDone: steps.count - remaining, checklistTotal: steps.count,
            hasTargetCommit: plan.targetCommitSHA != nil, targetCI: plan.targetCommitSHA == nil ? nil : targetCI,
            isCheckedOnGitHub: isCheckedOnGitHub, commitSummaries: changes?.commits.map(\.summary) ?? [],
            baseTag: changes?.baseTag)
    }

    static func attentionItem(for issue: ReleaseIssue, latestPassingSHA: String?) -> ReleaseBriefAttention {
        let key: String
        let action: ReleaseBriefAction?
        switch issue.kind {
        case .noRepository, .repositoryDisconnected:
            key = "repository"
            action = .show(.target)
        case .noTargetCommit:
            key = "commit"
            action = latestPassingSHA.map { .useCommit(sha: $0) } ?? .show(.target)
        case .noTag, .invalidTag, .tagExists, .tagDoesNotMatchVersion:
            key = "tag"
            action = .show(.target)
        case .tagExistsAtTarget:
            key = "tag-at-target"
            action = nil
        case .releasePublished(_, let url):
            key = "published"
            action = .openURL(url)
        case .draftExists(_, let url):
            key = "existing-draft"
            action = .openURL(url)
        case .notesTooLong, .emptyNotes:
            key = "notes"
            action = .show(.notes)
        case .incompleteTasks, .noTasks:
            key = "tasks"
            action = .show(.tasks)
        case .checklistIncomplete:
            key = "checklist"
            action = .show(.checklist)
        case .versionNotNewer:
            key = "version"
            action = .editPlan
        case .releaseListIncomplete:
            key = "release-list"
            action = .checkOnGitHub
        }
        return ReleaseBriefAttention(
            key: key, kind: .issue(issue.kind), severity: issue.severity, message: issue.message, action: action)
    }

    // MARK: The standard brief

    /// The brief without a model: Relvora's own headline and summary, the tasks grouped by type, and the most
    /// severe item as the next step.
    public static func standard(_ facts: ReleaseBriefFacts) -> ReleaseBrief {
        let verdict = facts.verdict
        let sections: [ReleaseBrief.Section] =
            verdict == .blocked ? [.attention, .progress, .themes] : [.themes, .attention, .progress]
        return ReleaseBrief(
            verdict: verdict, headline: standardHeadline(facts), summary: standardSummary(facts), changesTitle: nil,
            nextStep: standardNextStep(facts), sections: sections, themes: themesByType(facts.tasks),
            attention: facts.attention, source: .standard)
    }

    static func standardHeadline(_ facts: ReleaseBriefFacts) -> String {
        let blocking = facts.attention.filter { $0.severity == .blocking }.count
        let warnings = facts.attention.filter { $0.severity == .warning }.count
        switch facts.verdict {
        case .blocked:
            return "\(blocking) \(blocking == 1 ? "thing" : "things") to fix before the draft"
        case .almostReady:
            return "Nothing blocks the draft; \(warnings) \(warnings == 1 ? "thing" : "things") to look at first"
        case .ready:
            return facts.isCheckedOnGitHub ? "Checked on GitHub and ready for a draft" : "Ready for a draft"
        }
    }

    static func standardSummary(_ facts: ReleaseBriefFacts) -> String {
        guard !facts.tasks.isEmpty else { return "No tasks are assigned to \(facts.version) yet." }
        let counts = TaskType.allCases.compactMap { type -> String? in
            let count = facts.tasks.filter { $0.type == type }.count
            return count == 0 ? nil : "\(count) \(count == 1 ? type.singularNoun : type.pluralNoun)"
        }
        let done =
            facts.doneCount == facts.tasks.count
            ? "All of them are done." : "\(facts.doneCount) of \(facts.tasks.count) are done."
        return "\(facts.version) has \(listed(counts)). \(done)"
    }

    static func standardNextStep(_ facts: ReleaseBriefFacts) -> ReleaseBrief.NextStep? {
        if let first = facts.attention.first(where: { $0.severity != .note && $0.action != nil }),
            let action = first.action
        {
            return .init(action: action, reason: first.message)
        }
        guard facts.verdict != .blocked else { return nil }
        return draftStep
    }

    static let draftStep = ReleaseBrief.NextStep(
        action: .createDraft, reason: "Nothing blocks the draft. Relvora checks GitHub again before creating it.")

    static func themesByType(_ tasks: [ReleaseBriefFacts.TaskFact]) -> [ReleaseBrief.Theme] {
        TaskType.allCases.compactMap { type in
            let members = tasks.filter { $0.type == type }
            return members.isEmpty ? nil : .init(title: type.pluralTitle, symbol: type.briefSymbol, tasks: members)
        }
    }

    // MARK: The model's brief

    /// Checks what the model composed against the facts: unknown tasks, keys, sections, and symbols are dropped,
    /// every attention item is shown (most severe first), and the next step must be one Relvora offers. Once complete,
    /// tasks the model left out are listed under "Other", so nothing is hidden.
    public static func resolve(
        _ composition: ReleaseBriefComposition, facts: ReleaseBriefFacts, isComplete: Bool
    ) -> ReleaseBrief {
        let verdict = facts.verdict

        // Themes: each task once, in the first theme that names it.
        let tasksByRef = Dictionary(uniqueKeysWithValues: facts.tasks.map { ($0.ref, $0) })
        var placed = Set<String>()
        var themes: [ReleaseBrief.Theme] = []
        for theme in composition.themes ?? [] {
            let members = (theme.taskRefs ?? []).compactMap { ref -> ReleaseBriefFacts.TaskFact? in
                let ref = ref.trimmingCharacters(in: .whitespaces).uppercased()
                guard let task = tasksByRef[ref], placed.insert(ref).inserted else { return nil }
                return task
            }
            guard let title = cleaned(theme.title, limit: 40), !members.isEmpty, themes.count < maximumThemes,
                !themes.contains(where: { $0.title == title })
            else { continue }
            let symbol = theme.symbol.flatMap { themeSymbols.contains($0) ? $0 : nil } ?? dominantSymbol(members)
            themes.append(.init(title: title, symbol: symbol, tasks: members))
        }
        if isComplete {
            let rest = facts.tasks.filter { !placed.contains($0.ref) }
            if !rest.isEmpty {
                let title =
                    themes.isEmpty
                    ? "Tasks" : themes.contains(where: { $0.title == "Other" }) ? "Also in This Release" : "Other"
                themes.append(.init(title: title, symbol: "circle.dashed", tasks: rest))
            }
        }

        // Attention: everything, the most severe first; within a severity, the model's order.
        let order = (composition.attentionOrder ?? []).enumerated().reduce(into: [String: Int]()) { result, entry in
            if result[entry.element] == nil { result[entry.element] = entry.offset }
        }
        let attention = facts.attention.enumerated()
            .sorted { lhs, rhs in
                let left = (lhs.element.severity, order[lhs.element.key] ?? Int.max, lhs.offset)
                let right = (rhs.element.severity, order[rhs.element.key] ?? Int.max, rhs.offset)
                return left < right
            }
            .map(\.element)

        // Sections: the model's order, then any it left out. Something blocking always comes before the themes.
        var sections: [ReleaseBrief.Section] = []
        for name in composition.layout ?? [] {
            if let section = ReleaseBrief.Section(rawValue: name.lowercased()), !sections.contains(section) {
                sections.append(section)
            }
        }
        for section in ReleaseBrief.Section.allCases where !sections.contains(section) { sections.append(section) }
        if verdict == .blocked, let attentionIndex = sections.firstIndex(of: .attention),
            let themesIndex = sections.firstIndex(of: .themes), themesIndex < attentionIndex
        {
            sections.remove(at: attentionIndex)
            sections.insert(.attention, at: themesIndex)
        }

        return ReleaseBrief(
            verdict: verdict, headline: cleaned(composition.headline, limit: 120),
            summary: cleaned(composition.summary, limit: 400),
            changesTitle: facts.commitSummaries.isEmpty ? nil : cleaned(composition.changesTitle, limit: 80),
            nextStep: nextStep(composition, facts: facts, isComplete: isComplete), sections: sections,
            themes: themes, attention: attention, source: .model(isComplete: isComplete))
    }

    /// The model's next step when it's one Relvora offers, and a blocking one whenever something blocks the draft;
    /// otherwise the standard one.
    static func nextStep(
        _ composition: ReleaseBriefComposition, facts: ReleaseBriefFacts, isComplete: Bool
    ) -> ReleaseBrief.NextStep? {
        let reason = cleaned(composition.nextStepReason, limit: 200)
        if let key = composition.nextStep?.trimmingCharacters(in: .whitespaces) {
            if key == draftKey, facts.verdict != .blocked {
                return .init(action: .createDraft, reason: reason ?? draftStep.reason)
            }
            if let item = facts.attention.first(where: { $0.key == key }), let action = item.action,
                facts.verdict != .blocked || item.severity == .blocking
            {
                return .init(action: action, reason: reason ?? item.message)
            }
        }
        // While streaming, the next step waits for the model rather than showing one and swapping it.
        return isComplete ? standardNextStep(facts) : nil
    }

    // MARK: The prompt

    /// The model's standing instructions.
    public static let instructions = """
        You compose the release brief that Relvora, a Mac app for planning software releases, shows above a version \
        being prepared. Use only the facts you are given: never invent tasks, pull requests, numbers, names, or dates. \
        Write short, plain, friendly English for the developer who is releasing. The headline says where the release \
        stands in at most 12 words. The summary says what the release brings, in one or two sentences. Group the tasks \
        into a few themes by what they change for the app's users, with short titles. The changes title names what \
        the commits do in a few words, like a pull request title. Copy task refs, attention keys, and next step keys \
        exactly as given.
        """

    /// The facts as the model reads them: compact lines, at most `maximumTasks` tasks.
    public static func prompt(_ facts: ReleaseBriefFacts) -> String {
        var lines: [String] = []
        var heading = "Version \(facts.version)"
        if let title = facts.title, !title.isEmpty { heading += " “\(clipped(title))”" }
        if let date = facts.plannedDate {
            heading += ", planned for \(date.formatted(.iso8601.year().month().day()))"
        }
        lines.append(heading + ". Status: \(facts.verdict.title.lowercased()).")

        lines.append("")
        lines.append("TASKS (ref | type | state | title):")
        if facts.tasks.isEmpty { lines.append("none") }
        for task in facts.tasks.prefix(maximumTasks) {
            let state = task.isDone ? "done" : (task.column.map { "open, in \($0)" } ?? "open")
            lines.append("\(task.ref) | \(task.type.singularNoun) | \(state) | \(clipped(task.title))")
        }
        if facts.tasks.count > maximumTasks { lines.append("…and \(facts.tasks.count - maximumTasks) more") }

        lines.append("")
        lines.append("ATTENTION (key | severity | message):")
        if facts.attention.isEmpty { lines.append("none") }
        for item in facts.attention {
            lines.append("\(item.key) | \(item.severity.word) | \(item.message)")
        }

        if !facts.commitSummaries.isEmpty {
            lines.append("")
            lines.append("COMMITS since \(facts.baseTag ?? "the start") (newest first):")
            for summary in facts.commitSummaries.prefix(maximumCommits) { lines.append("- \(clipped(summary))") }
            if facts.commitSummaries.count > maximumCommits {
                lines.append("…and \(facts.commitSummaries.count - maximumCommits) more")
            }
        }

        lines.append("")
        lines.append("CHECKLIST: \(facts.checklistDone) of \(facts.checklistTotal) steps done.")
        if facts.hasTargetCommit {
            lines.append("CI ON THE SELECTED COMMIT: \(facts.targetCI?.title ?? "not read yet").")
        }
        lines.append("CHECKED ON GITHUB: \(facts.isCheckedOnGitHub ? "yes" : "no").")
        lines.append("NEXT STEP CHOICES: \(facts.nextStepKeys.joined(separator: ", ")).")
        lines.append("SECTIONS: themes, attention, progress.")
        lines.append("THEME SYMBOLS: \(themeSymbols.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    static func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    static func clipped(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
        return flat.count > maximumTitleLength ? String(flat.prefix(maximumTitleLength - 1)) + "…" : flat
    }

    static func dominantSymbol(_ tasks: [ReleaseBriefFacts.TaskFact]) -> String {
        let counts = Dictionary(grouping: tasks, by: \.type).mapValues(\.count)
        let type = TaskType.allCases.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? .other
        return type.briefSymbol
    }

    /// "3 features", "3 features and 2 bug fixes", "3 features, 1 improvement, and 2 bug fixes".
    static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

extension ReleaseIssue.Severity {
    var word: String {
        switch self {
        case .blocking: "blocking"
        case .warning: "warning"
        case .note: "note"
        }
    }
}

extension TaskType {
    /// The theme title for tasks of this type in the standard brief.
    public var pluralTitle: String {
        switch self {
        case .feature: "Features"
        case .improvement: "Improvements"
        case .bugFix: "Bug Fixes"
        case .documentation: "Documentation"
        case .maintenance: "Maintenance"
        case .other: "Other"
        }
    }

    /// The same symbols as the board's type badges.
    public var briefSymbol: String {
        switch self {
        case .feature: "sparkles"
        case .improvement: "wand.and.stars"
        case .bugFix: "ladybug"
        case .documentation: "doc.text"
        case .maintenance: "wrench.and.screwdriver"
        case .other: "circle.dashed"
        }
    }

    var singularNoun: String {
        switch self {
        case .feature: "feature"
        case .improvement: "improvement"
        case .bugFix: "bug fix"
        case .documentation: "documentation task"
        case .maintenance: "maintenance task"
        case .other: "other task"
        }
    }

    var pluralNoun: String {
        switch self {
        case .feature: "features"
        case .improvement: "improvements"
        case .bugFix: "bug fixes"
        case .documentation: "documentation tasks"
        case .maintenance: "maintenance tasks"
        case .other: "other tasks"
        }
    }
}

// MARK: - Writing

/// Whether a brief can be written by a model on this Mac.
public enum ReleaseBriefWriterStatus: Sendable, Equatable {
    case available
    case appleIntelligenceOff
    case deviceNotEligible
    /// Apple Intelligence is on, but its model is still downloading or preparing.
    case modelNotReady
    /// No model is used: turned off in Settings, or a test copy.
    case off

    public var explanation: String? {
        switch self {
        case .available: nil
        case .appleIntelligenceOff:
            "Turn on Apple Intelligence in System Settings to have the brief written for you."
        case .deviceNotEligible: "This Mac can’t run Apple Intelligence, so Relvora writes the brief from its rules."
        case .modelNotReady: "Apple Intelligence is still getting ready on this Mac. Try again in a few minutes."
        case .off: nil
        }
    }
}

/// Writes a brief's composition: the on-device model, or a scripted one in checks. Streams the composition as it
/// grows; the last element is the whole of it.
public protocol ReleaseBriefWriter: Sendable {
    var status: ReleaseBriefWriterStatus { get }
    func write(_ facts: ReleaseBriefFacts) -> AsyncThrowingStream<ReleaseBriefComposition, any Error>
}

/// A writer that never writes: Relvora shows its standard brief.
public struct NoReleaseBriefWriter: ReleaseBriefWriter {
    public init() {}

    public var status: ReleaseBriefWriterStatus { .off }

    public func write(_ facts: ReleaseBriefFacts) -> AsyncThrowingStream<ReleaseBriefComposition, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
