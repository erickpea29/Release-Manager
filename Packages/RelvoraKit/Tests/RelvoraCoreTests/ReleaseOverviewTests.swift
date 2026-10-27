import Foundation
import Testing

@testable import RelvoraCore

@Suite("Release overview (menu bar)")
struct ReleaseOverviewTests {
    private let acme = ProjectGroup(name: "Acme", sortOrder: 1)
    private let pilou = ProjectGroup(name: "Pilou", sortOrder: 2)

    private func project(_ name: String, in group: ProjectGroup? = nil) -> Project {
        Project(name: name, groupID: group?.id)
    }

    private func plan(_ project: Project, _ version: String, _ status: ReleasePlanStatus = .planned) -> ReleasePlan {
        ReleasePlan(projectID: project.id, version: version, status: status)
    }

    private func overview(_ projects: [Project], _ plans: [ReleasePlan], groups: [ProjectGroup] = [])
        -> ReleaseOverview
    {
        ReleaseOverview(
            sections: ProjectGrouping.sections(projects, groups: groups),
            activePlans: Dictionary(uniqueKeysWithValues: plans.map { ($0.projectID, $0) }))
    }

    private func names(_ items: [ReleaseOverview.Item]) -> [String] {
        items.map { "\($0.project.name) \($0.plan.version)" }
    }

    @Test("Drafts waiting come first; each version is listed once, in the sidebar's order")
    func draftsAndVersions() {
        let app = project("App")
        let api = project("API", in: acme)
        let site = project("Site")
        let tools = project("Tools")
        let docs = project("Docs")
        let result = overview(
            [app, api, site, tools, docs],
            [
                plan(app, "1.2.0"), plan(api, "2.0.0", .draftCreated), plan(site, "3.0.0", .reconciliationNeeded),
                plan(tools, "0.9.0", .published),
            ], groups: [acme])
        #expect(names(result.drafts) == ["API 2.0.0", "Site 3.0.0"])
        #expect(result.versions.map(\.title) == ["Versions in Progress"])
        #expect(names(result.versions[0].items) == ["App 1.2.0"])
        #expect(!result.isEmpty)
    }

    @Test("A long list across groups is listed under each group, then Other Projects; empty groups are left out")
    func longListUsesGroups() {
        let grouped = (1...3).map { project("Acme \($0)", in: acme) }
        let others = (1...3).map { project("Other \($0)") }
        let all = grouped + others
        let result = overview(all, all.map { plan($0, "1.0.0") }, groups: [acme, pilou])
        #expect(result.versions.map(\.title) == ["Acme", "Other Projects"])
        #expect(result.versions.map(\.items.count) == [3, 3])
        #expect(result.drafts.isEmpty)
    }

    @Test("A short list, or a long one in a single section, stays under Versions in Progress")
    func shortListStaysTogether() {
        let few = [project("A", in: acme), project("B")]
        let short = overview(few, few.map { plan($0, "1.0.0") }, groups: [acme])
        #expect(short.versions.map(\.title) == ["Versions in Progress"])
        #expect(short.versions[0].items.map(\.project.name) == ["A", "B"])

        let many = (1...6).map { project("Acme \($0)", in: acme) }
        let result = overview(many, many.map { plan($0, "1.0.0") }, groups: [acme, pilou])
        #expect(result.versions.map(\.title) == ["Versions in Progress"])
        #expect(result.versions[0].items.count == 6)
    }

    @Test("Nothing being planned is empty")
    func empty() {
        let app = project("App")
        #expect(overview([app], []).isEmpty)
        #expect(overview([app], [plan(app, "1.0.0", .cancelled)]).isEmpty)
        #expect(overview([], []).versions.isEmpty)
    }
}
