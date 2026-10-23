import Foundation

public enum ProjectGroupRules {
    /// The trimmed name, or throws if it is empty, too long, or already used by another group (ignoring case).
    /// `excluding` is the group being renamed.
    public static func validatedName(_ name: String, among groups: [ProjectGroup], excluding id: UUID? = nil)
        throws(ValidationError) -> String
    {
        let trimmed = try ProjectRules.validatedName(name)
        guard !groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { throw .duplicateGroupName(trimmed) }
        return trimmed
    }

    /// The groups to save to move `groupID` to `index` of `groups` (sidebar order, `index` counted after the move):
    /// only the moved group, or every group when its neighbours are too close to fit a key between them. Empty when
    /// nothing moves.
    public static func moving(_ groupID: UUID, to index: Int, in groups: [ProjectGroup], now: Date) -> [ProjectGroup] {
        guard let current = groups.firstIndex(where: { $0.id == groupID }) else { return [] }
        var others = groups
        var moved = others.remove(at: current)
        let target = min(max(index, 0), others.count)
        guard target != current else { return [] }
        let lower = target > 0 ? others[target - 1].sortOrder : nil
        let upper = target < others.count ? others[target].sortOrder : nil
        moved.updatedAt = now
        guard FractionalIndex.needsRenormalization(lower, upper) else {
            moved.sortOrder = FractionalIndex.between(lower, upper)
            return [moved]
        }
        others.insert(moved, at: target)
        return zip(others, FractionalIndex.renormalized(count: others.count)).map { group, order in
            var group = group
            group.sortOrder = order
            group.updatedAt = now
            return group
        }
    }
}

/// One section of the sidebar: a group and its projects, or the projects outside any group (`group == nil`).
public struct ProjectSection: Sendable, Hashable, Identifiable {
    public var group: ProjectGroup?
    public var projects: [Project]

    public var id: UUID? { group?.id }

    public init(group: ProjectGroup?, projects: [Project]) {
        self.group = group
        self.projects = projects
    }
}

public enum ProjectGrouping {
    /// Each group with its projects, in group order, then the projects outside any group. Projects keep their order.
    /// Empty groups are kept, so projects can be moved into them; while searching, only sections with a match are.
    /// A search matches a project's name and description, or its group's name.
    public static func sections(_ projects: [Project], groups: [ProjectGroup], query: String = "") -> [ProjectSection] {
        let groupIDs = Set(groups.map(\.id))
        let matching = ProjectSearch.filter(projects, query: query, groups: groups)
        var sections = groups.map { group in
            ProjectSection(group: group, projects: matching.filter { $0.groupID == group.id })
        }
        // A project whose group is missing (never expected) is listed outside any group rather than hidden.
        let ungrouped = matching.filter { project in project.groupID.map { !groupIDs.contains($0) } ?? true }
        if !ungrouped.isEmpty { sections.append(ProjectSection(group: nil, projects: ungrouped)) }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { sections.removeAll { $0.projects.isEmpty } }
        return sections
    }
}

/// Groups organize projects, for example by company: create, rename, reorder, delete. Deleting a group keeps its
/// projects; they are listed outside any group.
public struct ProjectGroupService: Sendable {
    private let repository: any ProjectGroupRepository
    private let now: @Sendable () -> Date

    public init(repository: any ProjectGroupRepository, now: @escaping @Sendable () -> Date = { .now }) {
        self.repository = repository
        self.now = now
    }

    /// Every group, in sidebar order.
    public func groups() async throws -> [ProjectGroup] {
        try await repository.groups()
    }

    /// Adds a group after the last one.
    public func create(name: String) async throws -> ProjectGroup {
        let existing = try await repository.groups()
        let group = ProjectGroup(
            name: try ProjectGroupRules.validatedName(name, among: existing),
            sortOrder: FractionalIndex.between(existing.last?.sortOrder, nil),
            createdAt: now())
        try await repository.save([group])
        return group
    }

    public func rename(_ group: ProjectGroup, to name: String) async throws -> ProjectGroup {
        var renamed = group
        renamed.name = try ProjectGroupRules.validatedName(
            name, among: try await repository.groups(), excluding: group.id)
        renamed.updatedAt = now()
        try await repository.save([renamed])
        return renamed
    }

    /// Moves a group to `index` in sidebar order. Returns every group, in the new order.
    public func move(_ groupID: UUID, to index: Int) async throws -> [ProjectGroup] {
        let changed = ProjectGroupRules.moving(groupID, to: index, in: try await repository.groups(), now: now())
        if !changed.isEmpty { try await repository.save(changed) }
        return try await repository.groups()
    }

    public func delete(_ groupID: UUID) async throws {
        try await repository.deleteGroup(id: groupID)
    }
}
