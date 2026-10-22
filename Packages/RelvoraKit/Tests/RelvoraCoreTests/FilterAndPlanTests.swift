import Foundation
import Testing

@testable import RelvoraCore

@Suite("Search and filters")
struct FilterTests {
    private let projectID = UUID()
    private let columnID = UUID()
    private let planID = UUID()

    private func task(
        _ title: String, priority: TaskPriority = .medium, type: TaskType = .feature, labels: [String] = [],
        plan: UUID? = nil, completed: Bool = false, details: String? = nil
    ) -> ProjectTask {
        ProjectTask(
            projectID: projectID, columnID: columnID, releasePlanID: plan, title: title, details: details,
            priority: priority, type: type, labels: labels, sortOrder: 1, completedAt: completed ? .now : nil)
    }

    @Test("Text search needs every term, ignoring case and accents")
    func textSearch() {
        #expect(TextSearch.matches("cafe MENU", fields: ["Café", "Lunch menu"]))
        #expect(!TextSearch.matches("cafe dinner", fields: ["Café", "Lunch menu"]))
        #expect(TextSearch.matches("   ", fields: []))
        let projects = [Project(name: "Relvora", details: "Release planning"), Project(name: "Website")]
        #expect(ProjectSearch.filter(projects, query: "release").map(\.name) == ["Relvora"])
    }

    @Test("Each filter dimension narrows the board")
    func dimensions() {
        let tasks = [
            task("Login", priority: .high, labels: ["Auth"], plan: planID),
            task("Docs", priority: .low, type: .documentation, completed: true, details: "Write the README"),
            task("Crash", priority: .urgent, type: .bugFix, labels: ["auth", "iOS"]),
        ]
        func titles(_ filter: TaskFilter) -> [String] { tasks.filter(filter.matches).map(\.title) }

        #expect(!TaskFilter().isActive)
        #expect(titles(TaskFilter()) == ["Login", "Docs", "Crash"])
        #expect(titles(TaskFilter(text: "readme")) == ["Docs"])
        #expect(titles(TaskFilter(text: "ios")) == ["Crash"])
        #expect(titles(TaskFilter(priorities: [.high, .urgent])) == ["Login", "Crash"])
        #expect(titles(TaskFilter(types: [.bugFix])) == ["Crash"])
        #expect(titles(TaskFilter(labels: ["AUTH"])) == ["Login", "Crash"])
        #expect(titles(TaskFilter(release: .plan(planID))) == ["Login"])
        #expect(titles(TaskFilter(release: .unassigned)) == ["Docs", "Crash"])
        #expect(titles(TaskFilter(hideCompleted: true)) == ["Login", "Crash"])
        #expect(titles(TaskFilter(priorities: [.urgent], labels: ["auth"], hideCompleted: true)) == ["Crash"])
    }
}

@Suite("Release plan rules")
struct ReleasePlanRulesTests {
    private let projectID = UUID()

    private func plan(_ version: String, _ status: ReleasePlanStatus = .planned) -> ReleasePlan {
        ReleasePlan(projectID: projectID, version: version, status: status)
    }

    @Test("Only one active plan per project")
    func oneActivePlan() throws {
        let active = plan("1.0.0")
        #expect(throws: ValidationError.activeReleasePlanExists(version: "1.0.0")) {
            try ReleasePlanRules.validated(plan("1.1.0"), existing: [active])
        }
        // Published and cancelled plans don't block a new one.
        _ = try ReleasePlanRules.validated(
            plan("1.1.0"), existing: [plan("1.0.0", .published), plan("1.0.1", .cancelled)])
        // Editing the active plan itself is fine.
        _ = try ReleasePlanRules.validated(active, existing: [active])
    }

    @Test("Versions must be unique by precedence, except for cancelled plans")
    func duplicates() throws {
        let published = plan("1.0.0", .published)
        for candidate in ["1.0.0", "v1.0.0", "1.0.0+build.7"] {
            // The message names the version as entered (normalized), build metadata included.
            #expect(throws: ValidationError.duplicateVersion(SemanticVersion(candidate)!.description)) {
                try ReleasePlanRules.validated(plan(candidate), existing: [published])
            }
        }
        _ = try ReleasePlanRules.validated(plan("1.0.0"), existing: [plan("1.0.0", .cancelled)])
        #expect(throws: ValidationError.duplicateVersion("Spring")) {
            try ReleasePlanRules.validated(plan("Spring"), existing: [plan("Spring", .published)])
        }
    }

    @Test("Plans are normalized and validated")
    func normalization() throws {
        var draft = plan("  2.0.0-beta.1 ")
        draft.title = "  "
        draft.targetBranch = " main "
        let normalized = try ReleasePlanRules.validated(draft, existing: [])
        #expect(normalized.version == "2.0.0-beta.1")
        #expect(normalized.title == nil)
        #expect(normalized.targetBranch == "main")
        #expect(throws: ValidationError.invalidVersion("")) { try ReleasePlanRules.validated(plan(""), existing: []) }
        draft.title = String(repeating: "t", count: ReleasePlanRules.maximumTitleLength + 1)
        #expect(throws: ValidationError.titleTooLong(maximum: ReleasePlanRules.maximumTitleLength)) {
            try ReleasePlanRules.validated(draft, existing: [])
        }
    }

    @Test("Only planned plans are editable; drafts and published plans are kept")
    func lifecycle() {
        #expect(ReleasePlanRules.isEditable(plan("1.0.0")))
        #expect(!ReleasePlanRules.isEditable(plan("1.0.0", .cancelled)))
        #expect(ReleasePlanRules.isDeletable(plan("1.0.0", .cancelled)))
        #expect(!ReleasePlanRules.isDeletable(plan("1.0.0", .published)))
        #expect(!ReleasePlanRules.isDeletable(plan("1.0.0", .draftCreated)))
    }
}
