import Foundation
import RelvoraCore
import Testing

@testable import RelvoraWidgetData

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ project: Project, _ version: String, status: ReleasePlanStatus = .planned) -> ReleasePlan {
        ReleasePlan(
            projectID: project.id, version: version, title: "Widgets", status: status, plannedDate: now,
            createdAt: now)
    }

    private func release(_ project: Project, _ version: String, state: ReleaseSnapshotState) -> ReleaseSnapshot {
        ReleaseSnapshot(
            projectID: project.id, releasePlanID: nil, origin: .relvoraDraft, version: version, title: nil,
            releaseName: version, tagName: "v\(version)", targetCommitSHA: String(repeating: "a", count: 40),
            targetBranch: "main", isPrerelease: false, releaseNotesMarkdown: "", tasks: [], changes: nil,
            githubRepositoryID: 1, repositoryFullName: "octo/app", repositoryURL: URL(string: "https://github.com")!,
            snapshotCreatedAt: now, state: state, publishedAt: state == .published ? now : nil)
    }

    @Test("Active projects are listed in the sidebar's order, with their group, next release, and last release")
    func make() {
        let pilou = ProjectGroup(name: "Pilou", sortOrder: 1)
        let web = Project(name: "Web", iconName: "globe", groupID: pilou.id)
        let relvora = Project(name: "Relvora")
        let old = Project(name: "Old", archivedAt: now)
        let app = Project(name: "App", groupID: pilou.id)
        let progress = [
            relvora.id: WidgetSnapshot.Progress(
                activePlan: plan(relvora, "0.2.4"), versionTaskCount: 8, versionDoneCount: 3,
                lastRelease: release(relvora, "0.2.3", state: .published)),
            web.id: WidgetSnapshot.Progress(
                activePlan: nil, versionTaskCount: 0, versionDoneCount: 0, lastRelease: nil),
        ]

        let snapshot = WidgetSnapshot.make(projects: [relvora, web, old, app], groups: [pilou], progress: progress)

        #expect(snapshot.format == WidgetSnapshot.currentFormat)
        #expect(snapshot.projects.map(\.name) == ["Web", "App", "Relvora"])
        #expect(snapshot.projects.map(\.groupName) == ["Pilou", "Pilou", nil])
        #expect(snapshot.projects.map(\.iconName) == ["globe", WidgetSnapshot.defaultIconName, "shippingbox"])
        let next = WidgetSnapshot.NextRelease(
            version: "0.2.4", title: "Widgets", status: .planned, doneCount: 3, taskCount: 8, plannedDate: now)
        #expect(snapshot.project(relvora.id)?.nextRelease == next)
        #expect(snapshot.project(relvora.id)?.lastRelease == .init(version: "0.2.3", publishedAt: now))
        // A project whose numbers aren't loaded yet, or with no version planned, has no next release.
        #expect(snapshot.project(app.id)?.nextRelease == nil)
        #expect(snapshot.project(web.id)?.nextRelease == nil)
        #expect(snapshot.project(old.id) == nil)
        #expect(snapshot.projectsWithNextRelease.map(\.id) == [relvora.id])
    }

    @Test("Only an active plan is a next release, and only a published release is the last one")
    func statuses() {
        let project = Project(name: "Relvora")
        for status in ReleasePlanStatus.allCases {
            let progress = WidgetSnapshot.Progress(
                activePlan: plan(project, "1.0.0", status: status), versionTaskCount: 1, versionDoneCount: 1,
                lastRelease: nil)
            let entry = WidgetSnapshot.make(projects: [project], groups: [], progress: [project.id: progress])
            #expect((entry.projects[0].nextRelease?.status) == (status.isActive ? status : nil))
        }
        for state in ReleaseSnapshotState.allCases {
            let progress = WidgetSnapshot.Progress(
                activePlan: nil, versionTaskCount: 0, versionDoneCount: 0,
                lastRelease: release(project, "0.9.0", state: state))
            let entry = WidgetSnapshot.make(projects: [project], groups: [], progress: [project.id: progress])
            #expect((entry.projects[0].lastRelease != nil) == (state == .published))
        }
    }

    @Test("Progress is done over total, none without tasks, and never above 1")
    func progress() {
        func next(_ done: Int, of total: Int) -> WidgetSnapshot.NextRelease {
            WidgetSnapshot.NextRelease(version: "1.0.0", status: .planned, doneCount: done, taskCount: total)
        }
        #expect(next(0, of: 0).progress == nil)
        #expect(next(3, of: 4).progress == 0.75)
        #expect(next(5, of: 4).progress == 1)
    }

    @Test("No projects make an empty snapshot")
    func empty() {
        let snapshot = WidgetSnapshot.make(
            projects: [], groups: [ProjectGroup(name: "Empty", sortOrder: 1)], progress: [:])
        #expect(snapshot.projects.isEmpty)
        #expect(snapshot.projectsWithNextRelease.isEmpty)
    }
}

@Suite("Widget snapshot file")
struct WidgetSnapshotStoreTests {
    private func temporaryStore() -> WidgetSnapshotStore {
        WidgetSnapshotStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshotTests-\(UUID().uuidString)"))
    }

    private let sample = WidgetSnapshot(projects: [
        .init(
            id: UUID(), name: "Relvora", iconName: "shippingbox", groupName: "Pilou",
            nextRelease: .init(
                version: "0.2.4", title: nil, status: .draftCreated, doneCount: 2, taskCount: 5,
                plannedDate: Date(timeIntervalSince1970: 1_800_000_000)),
            lastRelease: .init(version: "0.2.3", publishedAt: Date(timeIntervalSince1970: 1_799_000_000))),
        .init(id: UUID(), name: "Web", iconName: "globe"),
    ])

    @Test("A written snapshot reads back the same; writing again replaces it")
    func roundTrip() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        #expect(store.read() == nil)

        try store.write(sample)
        #expect(store.read() == sample)

        let emptied = WidgetSnapshot(projects: [])
        try store.write(emptied)
        #expect(store.read() == emptied)
    }

    @Test("A damaged file, or one in another format, reads as no snapshot")
    func unreadable() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.folder) }
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)

        try Data("{\"format\":1,\"projects\":[{\"name\":".utf8).write(to: store.fileURL)
        #expect(store.read() == nil)

        var newer = sample
        newer.format = WidgetSnapshot.currentFormat + 1
        try WidgetSnapshotStore.encode(newer).write(to: store.fileURL)
        #expect(store.read() == nil)
    }

    @Test("The same snapshot always encodes to the same bytes")
    func stableEncoding() throws {
        #expect(try WidgetSnapshotStore.encode(sample) == WidgetSnapshotStore.encode(sample))
        let json = try #require(String(data: WidgetSnapshotStore.encode(sample), encoding: .utf8))
        #expect(json.hasPrefix("{\"format\":1,"))
    }

    @Test("The shared group is the entitled one prefixed with the signing team's ID")
    func usableGroup() {
        let groups = ["group.com.example", "ABCDE12345.com.erickpea29.Relvora", "ABCDE12345.other"]
        #expect(WidgetSnapshotStore.usableGroup(teamID: "ABCDE12345", groups: groups) == groups[1])
        // Ad-hoc signed: no team, so no group, whatever the entitlements say.
        #expect(WidgetSnapshotStore.usableGroup(teamID: nil, groups: groups) == nil)
        #expect(WidgetSnapshotStore.usableGroup(teamID: "", groups: [".com.erickpea29.Relvora"]) == nil)
        #expect(WidgetSnapshotStore.usableGroup(teamID: "ZZZZZ99999", groups: groups) == nil)
        #expect(WidgetSnapshotStore.usableGroup(teamID: "ABCDE12345", groups: ["ABCDE12345."]) == nil)
        #expect(WidgetSnapshotStore.usableGroup(teamID: "ABCDE12345", groups: []) == nil)
    }

    @Test("A process without a team-prefixed App Group gets no shared store")
    func noSharedStoreWhenUnsigned() {
        // The test runner has no App Group entitlement.
        #expect(WidgetSnapshotStore.sharedContainerURL() == nil)
        #expect(WidgetSnapshotStore.shared() == nil)
    }
}

@Suite("Widget links")
struct WidgetLinkTests {
    @Test("A project's link and the Dashboard's read back as themselves")
    func roundTrip() {
        let id = UUID()
        #expect(WidgetLink.project(id).url.absoluteString == "relvora://project/\(id.uuidString)")
        #expect(WidgetLink(url: WidgetLink.project(id).url) == .project(id))
        #expect(WidgetLink(url: WidgetLink.dashboard.url) == .dashboard)
        #expect(WidgetLink(url: URL(string: "RELVORA://Project/\(id.uuidString.lowercased())")!) == .project(id))
    }

    @Test(
        "Other links are ignored",
        arguments: [
            "https://project/7B0F3C1E-3D6A-4C55-9A40-6F1E2D3C4B5A",
            "relvora://project/not-a-uuid",
            "relvora://project",
            "relvora://project/7B0F3C1E-3D6A-4C55-9A40-6F1E2D3C4B5A/board",
            "relvora://dashboard/extra",
            "relvora://settings",
        ])
    func ignored(_ text: String) {
        #expect(WidgetLink(url: URL(string: text)!) == nil)
    }
}
