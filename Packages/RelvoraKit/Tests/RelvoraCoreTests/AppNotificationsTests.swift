import Foundation
import Testing

@testable import RelvoraCore

@Suite("Notifications")
struct AppNotificationsTests {
    private let project = Project(name: "Relvora", createdAt: .now)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func plan(_ version: String, planned: Date?, status: ReleasePlanStatus = .planned) -> ReleasePlan {
        ReleasePlan(
            projectID: project.id, version: version, title: version == "0.3.0" ? "Notifications" : nil,
            status: status, plannedDate: planned, createdAt: .now)
    }

    @Test("Planned for today arrives at 9:00 on the planned day, and only while it's still ahead")
    func plannedFireDate() {
        // A date picked in the editor is the start of the day; any time that day counts as that day.
        #expect(AppNotifications.plannedFireDate(date(3, 0), now: date(1, 12), calendar: calendar) == date(3, 9))
        #expect(
            AppNotifications.plannedFireDate(date(3, 17), now: date(3, 8, minute: 59), calendar: calendar) == date(3, 9)
        )
        #expect(AppNotifications.plannedFireDate(date(3, 0), now: date(3, 9), calendar: calendar) == nil)
        #expect(AppNotifications.plannedFireDate(date(2, 0), now: date(3, 12), calendar: calendar) == nil)
    }

    @Test("Only active plans with a planned date ahead are scheduled")
    func plannedForToday() {
        let plans = [
            plan("0.3.0", planned: date(5, 0)), plan("0.2.9", planned: nil),
            plan("0.2.8", planned: date(5, 0), status: .published), plan("0.2.7", planned: date(1, 0)),
            plan("0.3.1", planned: date(6, 0), status: .draftCreated),
        ]
        let scheduled = AppNotifications.plannedForToday(plans, project: project, now: date(2, 12), calendar: calendar)
        #expect(scheduled.map(\.title) == ["Relvora 0.3.0 is planned for today", "Relvora 0.3.1 is planned for today"])
        #expect(scheduled.map(\.fireDate) == [date(5, 9), date(6, 9)])
        #expect(scheduled[0].id == AppNotifications.plannedPrefix + plans[0].id.uuidString)
        #expect(scheduled[0].body.contains("(Notifications)"))
        #expect(scheduled[0].target == .project(project.id, tab: "releases"))

        var archived = project
        archived.archivedAt = .now
        #expect(
            AppNotifications.plannedForToday(plans, project: archived, now: date(2, 12), calendar: calendar).isEmpty)
    }

    @Test("Updates and Claude's tasks say what happened and open the right place")
    func wording() {
        let update = AppNotifications.updateAvailable(SemanticVersion("0.2.2")!, current: SemanticVersion("0.2.1"))
        #expect(update.title == "Relvora 0.2.2 is available" && update.body.hasPrefix("You have 0.2.1."))
        #expect(update.target == .update && update.id == "update-0.2.2")

        let one = AppNotifications.claudeAddedTasks(
            count: 1, projectID: project.id, projectName: "Relvora", version: "0.2.2")
        #expect(one.title == "Claude added 1 task" && one.body == "To Relvora 0.2.2. They’re labeled “claude”.")
        #expect(one.target == .project(project.id, tab: "board"))
        let backlog = AppNotifications.claudeAddedTasks(
            count: 3, projectID: project.id, projectName: "Relvora", version: nil)
        #expect(backlog.title == "Claude added 3 tasks" && backlog.body.hasPrefix("To the Backlog of Relvora."))
        #expect(backlog.target == .project(project.id, tab: "backlog") && backlog.id != one.id)
    }

    @Test("A publication is announced once, and not the ones there before Relvora looked")
    func newlyPublished() throws {
        let sha = String(repeating: "a", count: 40)
        let draft = ReleaseSnapshot(
            projectID: project.id, releasePlanID: UUID(), origin: .relvoraDraft, version: "0.2.1", title: nil,
            releaseName: "0.2.1", tagName: "v0.2.1", targetCommitSHA: sha, targetBranch: "main", isPrerelease: false,
            releaseNotesMarkdown: "", tasks: [], changes: nil, githubRepositoryID: 42,
            repositoryFullName: "octo/relvora", repositoryURL: URL(string: "https://github.com/octo/relvora")!,
            snapshotCreatedAt: .now)
        let url = URL(string: "https://github.com/octo/relvora/releases/tag/v0.2.1")!
        let published = try #require(
            draft.applying(.draftConfirmed(releaseID: 1, url: url), at: .now)?
                .applying(.published(at: .now, url: url, notes: nil, tagName: "v0.2.1", commitSHA: sha), at: .now))

        #expect(AppNotifications.newlyPublished([published], known: nil).isEmpty)
        #expect(AppNotifications.newlyPublished([draft], known: []).isEmpty)
        #expect(AppNotifications.newlyPublished([published], known: [published.id]).isEmpty)
        // Known projects announce publications they haven't seen.
        #expect(AppNotifications.newlyPublished([published], known: [UUID()]) == [published])

        let content = AppNotifications.published(published, project: project)
        #expect(content.title == "Relvora 0.2.1 is published")
        #expect(content.body == "GitHub has the release v0.2.1, verified at aaaaaaa in octo/relvora.")
    }

    @Test("Every kind has a title and an explanation for Settings")
    func kinds() {
        #expect(NotificationKind.allCases.count == 5)
        #expect(NotificationKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.explanation.isEmpty })
    }
}
