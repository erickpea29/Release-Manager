import Foundation

/// A project's release checklist: the steps to tick on every release plan before its draft is created.
public struct ReleaseChecklistService: Sendable {
    private let steps: any ReleaseStepRepository
    private let plans: ReleasePlanService
    private let now: @Sendable () -> Date

    public init(
        steps: any ReleaseStepRepository, plans: any ReleasePlanRepository,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.steps = steps
        self.plans = ReleasePlanService(repository: plans, now: now)
        self.now = now
    }

    public func steps(projectID: UUID) async throws -> [ReleaseStep] {
        try await steps.steps(projectID: projectID)
    }

    /// Saves the edited checklist in its new order. Blank steps are dropped; existing steps keep their ticks.
    @discardableResult
    public func save(_ edited: [ReleaseStep], projectID: UUID) async throws -> [ReleaseStep] {
        let validated = try ReleaseChecklist.validated(edited, projectID: projectID, now: now())
        try await steps.replaceSteps(validated, projectID: projectID)
        return validated
    }

    /// Ticks or unticks a step on a plan that is still being planned.
    public func setStep(_ stepID: UUID, done: Bool, on plan: ReleasePlan) async throws -> ReleasePlan {
        guard ReleasePlanRules.isEditable(plan) else { throw ValidationError.releasePlanLocked(plan.status) }
        var edited = plan
        if done { edited.completedStepIDs.insert(stepID) } else { edited.completedStepIDs.remove(stepID) }
        guard edited.completedStepIDs != plan.completedStepIDs else { return plan }
        return try await plans.update(edited)
    }
}
