import XCTest

/// Notifications (ADR 0019). Test builds record them instead of showing them, so the test reads them in Settings:
/// a draft published on the demo GitHub, an update found by the automatic check, and tasks Claude created.
@MainActor
final class NotificationUITests: XCTestCase {
    private let port = 47_912
    private let key = "rlv_UITestKey_notifications_0123456789abcdef"

    func testEventsAreNotifiedAndEachKindCanBeTurnedOff() async throws {
        let app = RelvoraApp.launchProject(
            tab: "releases",
            [
                "-RelvoraDemoScenario", "published", "-RelvoraDemoUpdateVersion", "9.9.0",
                "-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key,
            ])
        app.text("Published on GitHub", exact: true).wait(30)
        app.buttons["updateAvailable"].wait(30)
        // 0.2.0 is published, so no version is being planned: Claude adds to the Backlog.
        let created = try await MCPTestClient(port: port, key: key).call(
            "create_tasks", ["project": "Relvora", "destination": "backlog", "tasks": [["title": "Notified task"]]])
        XCTAssertEqual(created["isError"] as? Bool, false)

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Notifications"].wait().click()
        app.text("Relvora 0.2.0 is published").wait(10)
        app.text("Relvora 9.9.0 is available").wait()
        app.text("Claude added 1 task").wait()
        screenshot(app, "settings-notifications")

        let claude = app.switches["notify-claudeAddedTasks"].wait()
        XCTAssertEqual(claude.value as? Int, 1)
        XCTAssertEqual(claude.label, "Claude added tasks")
        claude.click()
        XCTAssertEqual(claude.value as? Int, 0)

        _ = try await MCPTestClient(port: port, key: key).call(
            "create_tasks", ["project": "Relvora", "destination": "backlog", "tasks": [["title": "Quiet task"]]])
        try await Task.sleep(for: .seconds(1))
        let recorded = app.descendants(matching: .any).matching(identifier: "recordedNotification")
        XCTAssertEqual(recorded.matching(NSPredicate(format: "value BEGINSWITH 'Claude added'")).count, 1)
    }
}
