import Foundation

/// The versions being planned across active projects, as the menu bar icon lists them (ADR 0022). Drafts waiting come
/// first; each version is listed once.
public struct ReleaseOverview: Sendable, Equatable {
    /// A version being planned, with its project.
    public struct Item: Sendable, Equatable, Identifiable {
        public let project: Project
        public let plan: ReleasePlan

        public var id: UUID { plan.id }
    }

    /// Versions under one heading: "Versions in Progress", or a group's name in a long list.
    public struct Section: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let items: [Item]
    }

    /// Above this many versions in progress, they're listed under their groups.
    public static let groupingThreshold = 5

    /// Versions whose draft is on GitHub and not yet published, or that need reconciliation.
    public let drafts: [Item]
    /// The other versions being planned.
    public let versions: [Section]

    public var isEmpty: Bool { drafts.isEmpty && versions.isEmpty }

    /// `sections` are the sidebar's, with active projects only; `activePlans` holds each project's version being
    /// planned. Items keep the sidebar's order. More than `groupingThreshold` versions in progress, from more than one
    /// section, are listed under their group's name, then "Other Projects".
    public init(sections: [ProjectSection], activePlans: [UUID: ReleasePlan]) {
        let waiting: Set<ReleasePlanStatus> = [.draftCreated, .reconciliationNeeded]
        let listed = sections.map { section in
            (
                section: section,
                items: section.projects.compactMap { project -> Item? in
                    guard let plan = activePlans[project.id], plan.status.isActive else { return nil }
                    return Item(project: project, plan: plan)
                }
            )
        }
        drafts = listed.flatMap(\.items).filter { waiting.contains($0.plan.status) }

        let inProgress = listed.map { entry in
            (section: entry.section, items: entry.items.filter { !waiting.contains($0.plan.status) })
        }
        .filter { !$0.items.isEmpty }
        let count = inProgress.reduce(0) { $0 + $1.items.count }
        if count > Self.groupingThreshold && inProgress.count > 1 {
            versions = inProgress.map { entry in
                Section(
                    id: entry.section.group?.id.uuidString ?? "other",
                    title: entry.section.group?.name ?? "Other Projects", items: entry.items)
            }
        } else if count > 0 {
            versions = [Section(id: "versions", title: "Versions in Progress", items: inProgress.flatMap(\.items))]
        } else {
            versions = []
        }
    }
}
