import Foundation
import Testing

@testable import RelvoraCore

@Suite("Project groups")
struct ProjectGroupTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func groups(_ names: String...) -> [ProjectGroup] {
        names.enumerated().map { ProjectGroup(name: $1, sortOrder: Double($0 + 1)) }
    }

    private func order(_ groups: [ProjectGroup], after changes: [ProjectGroup]) -> [String] {
        let changed = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        return groups.map { changed[$0.id] ?? $0 }.sorted { $0.sortOrder < $1.sortOrder }.map(\.name)
    }

    @Test("Names are trimmed and unique ignoring case; a group keeps its own name when renamed")
    func names() throws {
        let existing = groups("Pilou", "Relvora")
        #expect(try ProjectGroupRules.validatedName("  Acme ", among: existing) == "Acme")
        #expect(throws: ValidationError.duplicateGroupName("pilou")) {
            try ProjectGroupRules.validatedName("pilou", among: existing)
        }
        #expect(try ProjectGroupRules.validatedName("PILOU", among: existing, excluding: existing[0].id) == "PILOU")
        #expect(throws: ValidationError.emptyName) { try ProjectGroupRules.validatedName(" ", among: existing) }
    }

    @Test("Moving a group changes only its own position", arguments: [(2, 0), (0, 2), (1, 2), (0, 1)])
    func move(from: Int, to: Int) {
        let all = groups("A", "B", "C")
        let changes = ProjectGroupRules.moving(all[from].id, to: to, in: all, now: now)
        #expect(changes.count == 1 && changes[0].id == all[from].id && changes[0].updatedAt == now)
        var expected = all.map(\.name)
        expected.insert(expected.remove(at: from), at: to)
        #expect(order(all, after: changes) == expected)
    }

    @Test("A move to the same place, or of an unknown group, changes nothing")
    func noMove() {
        let all = groups("A", "B")
        #expect(ProjectGroupRules.moving(all[1].id, to: 1, in: all, now: now).isEmpty)
        #expect(ProjectGroupRules.moving(all[1].id, to: 9, in: all, now: now).isEmpty)
        #expect(ProjectGroupRules.moving(UUID(), to: 0, in: all, now: now).isEmpty)
    }

    @Test("Neighbours too close to split renumber every group, in the new order")
    func renormalize() {
        var all = groups("A", "B", "C")
        all[1].sortOrder = 1 + 1e-10
        let changes = ProjectGroupRules.moving(all[2].id, to: 1, in: all, now: now)
        #expect(changes.map(\.name) == ["A", "C", "B"])
        #expect(changes.map(\.sortOrder) == [1, 2, 3])
    }

    @Test("Sections list groups in order with their projects, then projects outside any group")
    func sections() {
        let all = groups("Pilou", "Empty")
        let web = Project(name: "Web", groupID: all[0].id)
        let side = Project(name: "Side")
        let api = Project(name: "API", details: "Backend", groupID: all[0].id)
        let lost = Project(name: "Lost", groupID: UUID())
        let sections = ProjectGrouping.sections([web, side, api, lost], groups: all)
        #expect(sections.map(\.group?.name) == ["Pilou", "Empty", nil])
        #expect(sections.map { $0.projects.map(\.name) } == [["Web", "API"], [], ["Side", "Lost"]])

        #expect(ProjectGrouping.sections([web], groups: []).map(\.group) == [nil])
        #expect(ProjectGrouping.sections([], groups: []).isEmpty)
    }

    @Test("Searching matches a project or its group's name and hides sections without a match")
    func search() {
        let all = groups("Pilou", "Relvora")
        let web = Project(name: "Web", groupID: all[0].id)
        let app = Project(name: "App", details: "Backend", groupID: all[1].id)
        let side = Project(name: "Side")
        let projects = [web, app, side]
        #expect(ProjectGrouping.sections(projects, groups: all, query: "pilou").map(\.group?.name) == ["Pilou"])
        #expect(ProjectGrouping.sections(projects, groups: all, query: "backend").flatMap(\.projects) == [app])
        #expect(ProjectGrouping.sections(projects, groups: all, query: "side").map(\.group) == [nil])
        #expect(ProjectGrouping.sections(projects, groups: all, query: "nothing").isEmpty)
    }
}
