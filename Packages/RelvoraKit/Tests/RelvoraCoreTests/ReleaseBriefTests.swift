import Foundation
import Testing

@testable import RelvoraCore

@Suite("Release brief")
struct ReleaseBriefTests {
    private let projectID = UUID()
    private let todo = UUID()
    private let review = UUID()
    private let sha = String(repeating: "a", count: 40)
    private let passingSHA = String(repeating: "b", count: 40)

    private func makePlan(target: String? = nil) -> ReleasePlan {
        ReleasePlan(projectID: projectID, version: "0.2.5", title: "Briefs", targetCommitSHA: target)
    }

    private func task(
        _ title: String, _ type: TaskType = .feature, done: Bool = false, in plan: ReleasePlan, order: Double
    ) -> ProjectTask {
        ProjectTask(
            projectID: projectID, columnID: done ? review : todo, releasePlanID: plan.id, title: title, type: type,
            sortOrder: order, completedAt: done ? .now : nil)
    }

    private func pull(_ number: Int, draft: Bool = false) -> PullRequest {
        PullRequest(
            number: number, title: "Change \(number)", authorLogin: "octo", state: .open, isDraft: draft,
            headRef: "change-\(number)", headSHA: String(repeating: "c", count: 40), baseRef: "main", mergedAt: nil,
            mergeCommitSHA: nil, updatedAt: nil, htmlURL: URL(string: "https://github.com/octo/app/pull/\(number)")!)
    }

    private func gather(
        plan: ReleasePlan, tasks: [ProjectTask] = [], issues: [ReleaseIssue] = [], steps: [ReleaseStep] = [],
        targetCI: CIStatus? = nil, latestPassingSHA: String? = nil, pulls: [(PullRequest, MergeReadiness)] = []
    ) -> ReleaseBriefFacts {
        ReleaseBriefComposer.facts(
            plan: plan, tasks: tasks, columnNames: [todo: "To Do", review: "Done"], issues: issues,
            isCheckedOnGitHub: false, steps: steps, targetCI: targetCI, latestPassingSHA: latestPassingSHA,
            pullRequests: pulls)
    }

    // MARK: Facts

    @Test("Tasks get short refs; each issue gets a stable key and the action that deals with it")
    func factsFromThePlan() {
        let plan = makePlan()
        let tasks = [
            task("Brief", in: plan, order: 1), task("Crash on launch", .bugFix, done: true, in: plan, order: 2),
            ProjectTask(projectID: projectID, columnID: todo, title: "Elsewhere", sortOrder: 3),
        ]
        let facts = gather(
            plan: plan, tasks: tasks,
            issues: [.init(.noTargetCommit), .init(.emptyNotes), .init(.incompleteTasks(count: 1))],
            latestPassingSHA: passingSHA)

        #expect(facts.tasks.map(\.ref) == ["T1", "T2"])
        #expect(facts.tasks.map(\.column) == ["To Do", "Done"])
        #expect(facts.doneCount == 1)
        #expect(facts.attention.map(\.key) == ["commit", "notes", "tasks"])
        #expect(facts.attention[0].action == .useCommit(sha: passingSHA))
        #expect(facts.attention[1].action == .show(.notes))
        #expect(facts.attention[2].action == .show(.tasks))
        #expect(facts.verdict == .blocked)
        #expect(facts.nextStepKeys == ["commit", "notes", "tasks"])
    }

    @Test("One item per key, the most severe, and the most severe first")
    func attentionIsUniqueAndOrdered() {
        let plan = makePlan()
        let facts = gather(
            plan: plan,
            issues: [
                .init(.tagDoesNotMatchVersion(tag: "v9", version: "0.2.5")), .init(.noTag), .init(.noTasks),
            ])
        #expect(facts.attention.map(\.key) == ["tag", "tasks"])
        #expect(facts.attention[0].severity == .blocking)
    }

    @Test("Failing CI on the selected commit offers the newer commit whose CI passed")
    func failingCI() {
        let plan = makePlan(target: sha)
        let facts = gather(
            plan: plan, targetCI: .failed(checks: ["Lint"], total: 3), latestPassingSHA: passingSHA)
        let ci = facts.attention.first { $0.key == "ci" }
        #expect(ci?.severity == .warning)
        #expect(ci?.message == "CI failed on the selected commit: Lint.")
        #expect(ci?.action == .useCommit(sha: passingSHA))
        #expect(facts.verdict == .almostReady)
    }

    @Test("A newer passing commit is a note; the selected commit's own passing CI isn't")
    func newerPassingCommit() {
        let passing = gather(plan: makePlan(target: sha), targetCI: .passed(total: 2), latestPassingSHA: passingSHA)
        #expect(passing.attention.map(\.key) == ["newer-commit"])
        #expect(passing.verdict == .ready)

        let same = gather(plan: makePlan(target: sha), targetCI: .passed(total: 2), latestPassingSHA: sha)
        #expect(same.attention.isEmpty)
    }

    @Test("Open pull requests: drafts are left out, at most four, and a ready one points at Merge")
    func pullRequests() {
        var pulls: [(PullRequest, MergeReadiness)] = [
            (pull(1), .ready), (pull(2, draft: true), .draft), (pull(3), .ciFailed),
        ]
        pulls += (4...8).map { (pull($0), MergeReadiness.waitingForCI) }
        let facts = gather(plan: makePlan(), pulls: pulls)
        let keys = facts.attention.map(\.key)
        #expect(keys.first == "pr-3", "CI failing is a warning, so it comes first")
        #expect(Set(keys) == ["pr-1", "pr-3", "pr-4", "pr-5"])
        #expect(facts.attention.first { $0.key == "pr-1" }?.action == .show(.pullRequests))
        #expect(facts.attention.first { $0.key == "pr-1" }?.message == "#1 “Change 1” is ready to merge into main.")
    }

    @Test("The fingerprint changes with what the brief is about")
    func fingerprint() {
        let plan = makePlan()
        let open = gather(plan: plan, tasks: [task("Brief", in: plan, order: 1)])
        let done = gather(plan: plan, tasks: [task("Brief", done: true, in: plan, order: 1)])
        #expect(open.fingerprint != done.fingerprint)
        #expect(open.fingerprint == gather(plan: plan, tasks: [task("Brief", in: plan, order: 1)]).fingerprint)
    }

    // MARK: The standard brief

    @Test("Without a model: the blocking items first, a summary by type, and the most severe item as the next step")
    func standardBrief() {
        let plan = makePlan()
        let tasks = [
            task("Brief", in: plan, order: 1), task("Themes", in: plan, order: 2),
            task("Crash", .bugFix, done: true, in: plan, order: 3),
        ]
        let facts = gather(plan: plan, tasks: tasks, issues: [.init(.noTargetCommit), .init(.emptyNotes)])
        let brief = ReleaseBriefComposer.standard(facts)

        #expect(brief.source == .standard)
        #expect(brief.headline == "1 thing to fix before the draft")
        #expect(brief.summary == "0.2.5 has 2 features and 1 bug fix. 1 of 3 are done.")
        #expect(brief.sections == [.attention, .progress, .themes])
        #expect(brief.themes.map(\.title) == ["Features", "Bug Fixes"])
        #expect(brief.themes.map(\.symbol) == ["sparkles", "ladybug"])
        #expect(brief.nextStep?.action == .show(.target))
        #expect(brief.nextStep?.reason == "Choose the commit to release.")
    }

    @Test("Ready: the next step is the draft, and the themes come first")
    func readyBrief() {
        let plan = makePlan(target: sha)
        let brief = ReleaseBriefComposer.standard(
            gather(plan: plan, tasks: [task("Brief", done: true, in: plan, order: 1)]))
        #expect(brief.verdict == .ready)
        #expect(brief.headline == "Ready for a draft")
        #expect(brief.summary == "0.2.5 has 1 feature. All of them are done.")
        #expect(brief.sections == [.themes, .attention, .progress])
        #expect(brief.nextStep?.action == .createDraft)
    }

    // MARK: The model's brief

    private var mixed: ReleaseBriefFacts {
        let plan = makePlan()
        return gather(
            plan: plan,
            tasks: [
                task("Brief", in: plan, order: 1), task("Themes", in: plan, order: 2),
                task("Crash", .bugFix, in: plan, order: 3),
            ],
            issues: [.init(.noTargetCommit), .init(.emptyNotes), .init(.incompleteTasks(count: 3))])
    }

    @Test("Themes keep only known tasks, each once; once complete, tasks left out are listed under Other")
    func resolvedThemes() {
        let composition = ReleaseBriefComposition(
            headline: "  Two features need a commit  ", summary: "Briefs arrive.",
            themes: [
                .init(title: "Smarter Releases", symbol: "sparkles", taskRefs: ["T1", "t2", "T9"]),
                .init(title: "Repeats", symbol: "bolt", taskRefs: ["T1"]),
                .init(title: "Untitled", symbol: "not.a.symbol", taskRefs: []),
            ])
        let streaming = ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: false)
        #expect(streaming.headline == "Two features need a commit")
        #expect(streaming.themes.map(\.title) == ["Smarter Releases"])
        #expect(streaming.themes[0].tasks.map(\.ref) == ["T1", "T2"])
        #expect(streaming.source == .model(isComplete: false))

        let complete = ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: true)
        #expect(complete.themes.map(\.title) == ["Smarter Releases", "Other"])
        #expect(complete.themes[1].tasks.map(\.ref) == ["T3"])
    }

    @Test("A symbol outside the list becomes the tasks' type symbol")
    func resolvedSymbol() {
        let composition = ReleaseBriefComposition(
            themes: [.init(title: "Fixes", symbol: "flame", taskRefs: ["T3"])])
        let brief = ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: true)
        #expect(brief.themes.first?.symbol == "ladybug")
    }

    @Test("Every attention item is shown, the most severe first, in the model's order within a severity")
    func resolvedAttention() {
        let composition = ReleaseBriefComposition(attentionOrder: ["tasks", "notes", "unknown", "commit"])
        let brief = ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: true)
        #expect(brief.attention.map(\.key) == ["commit", "tasks", "notes"])
    }

    @Test("The model's section order is kept, except that blocking items come before the themes")
    func resolvedLayout() {
        let composition = ReleaseBriefComposition(layout: ["Themes", "progress", "themes", "charts"])
        let blocked = ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: true)
        #expect(blocked.sections == [.attention, .themes, .progress])

        let plan = makePlan(target: sha)
        let ready = gather(plan: plan, tasks: [task("Brief", done: true, in: plan, order: 1)])
        let brief = ReleaseBriefComposer.resolve(composition, facts: ready, isComplete: true)
        #expect(brief.sections == [.themes, .progress, .attention])
    }

    @Test("The next step must be one Relvora offers, and a blocking one while something blocks the draft")
    func resolvedNextStep() {
        func next(_ key: String?, complete: Bool = true) -> ReleaseBrief.NextStep? {
            let composition = ReleaseBriefComposition(nextStep: key, nextStepReason: key.map { "Because \($0)." })
            return ReleaseBriefComposer.resolve(composition, facts: mixed, isComplete: complete).nextStep
        }
        #expect(next("commit")?.action == .show(.target))
        #expect(next("commit")?.reason == "Because commit.")
        // Not blocking, or not offered: the standard next step instead.
        #expect(next("tasks")?.action == .show(.target))
        #expect(next("draft")?.action == .show(.target))
        #expect(next("deploy")?.reason == "Choose the commit to release.")
        // While the model is still writing, no next step rather than one that changes.
        #expect(next("deploy", complete: false) == nil)
        #expect(next(nil, complete: false) == nil)
    }

    @Test("The draft is a next step only when nothing blocks it")
    func draftNextStep() {
        let plan = makePlan(target: sha)
        let facts = gather(
            plan: plan, tasks: [task("Brief", in: plan, order: 1)], issues: [.init(.incompleteTasks(count: 1))])
        #expect(facts.nextStepKeys == ["tasks", "draft"])
        let brief = ReleaseBriefComposer.resolve(
            ReleaseBriefComposition(nextStep: "draft", nextStepReason: "Ship it."), facts: facts, isComplete: true)
        #expect(brief.nextStep == .init(action: .createDraft, reason: "Ship it."))
    }

    // MARK: The prompt

    @Test("The prompt lists the tasks, the attention items, and the choices the model may copy")
    func prompt() {
        let prompt = ReleaseBriefComposer.prompt(mixed)
        #expect(prompt.hasPrefix("Version 0.2.5 “Briefs”. Status: not ready yet."))
        #expect(prompt.contains("T1 | feature | open, in To Do | Brief"))
        #expect(prompt.contains("T3 | bug fix | open, in To Do | Crash"))
        #expect(prompt.contains("commit | blocking | Choose the commit to release."))
        #expect(prompt.contains("NEXT STEP CHOICES: commit, notes, tasks."))
        #expect(prompt.contains("CHECKLIST: 0 of 0 steps done."))
    }

    @Test("The prompt stays small: at most 40 tasks, short titles on one line")
    func promptLimits() {
        let plan = makePlan()
        let long = String(repeating: "x", count: 200)
        let tasks =
            [task("Two\nlines | piped", in: plan, order: 0), task(long, in: plan, order: 1)]
            + (2..<50).map { task("Task \($0)", in: plan, order: Double($0)) }
        let prompt = ReleaseBriefComposer.prompt(gather(plan: plan, tasks: tasks))
        #expect(prompt.contains("T1 | feature | open, in To Do | Two lines / piped"))
        #expect(prompt.contains("| " + String(repeating: "x", count: 89) + "…"))
        #expect(prompt.contains("T40 |"))
        #expect(!prompt.contains("T41 |"))
        #expect(prompt.contains("…and 10 more"))
    }
}
