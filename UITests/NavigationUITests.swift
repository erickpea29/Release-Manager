import XCTest

@MainActor
final class NavigationUITests: XCTestCase {
    func testLaunchShowsDashboardAndSampleProjects() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        XCTAssertTrue(app.outlines.firstMatch.staticTexts["Relvora"].exists)
        XCTAssertTrue(app.staticTexts["Projects"].exists)
        screenshot(app, "dashboard")
    }

    func testQuickActionsAndGoShortcuts() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["quickActionsSearch"].wait()
        search.type("history")
        screenshot(app, "quick-actions")
        search.typeText("\r")
        app.text("No Releases Yet").wait()

        app.typeKey("1", modifierFlags: .command)
        app.staticTexts["Projects"].wait()

        // Quick actions open a project straight on its Releases tab.
        app.typeKey("k", modifierFlags: .command)
        app.textFields["quickActionsSearch"].wait().type("relvora releases\r")
        app.text("Kanban and backups").wait()
    }
}
