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

    /// Hiding the sidebar leaves a strip of icons that still opens views and projects.
    func testCollapsedSidebarShowsIcons() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        let rail = app.descendants(matching: .any)["sidebarRail"]
        XCTAssertFalse(rail.exists)

        app.typeKey("s", modifierFlags: [.control, .command])  // View › Hide Sidebar
        rail.wait()
        for name in ["Dashboard", "Release History", "Relvora", "New Project"] {
            XCTAssertTrue(rail.buttons[name].exists, "\(name) is missing from the collapsed sidebar")
        }
        // Views narrower than the window (an empty Release History) once pulled the strip to the middle.
        rail.buttons["Release History"].click()
        app.text("No Releases Yet").wait()
        // The strip's first icon is a few points in from the window's edge, not hundreds.
        XCTAssertLessThan(rail.frame.minX - app.windows["main"].frame.minX, 20)

        rail.buttons["Website Redesign"].click()
        app.text("Marketing site refresh").wait()
        XCTAssertTrue(rail.buttons["Website Redesign"].isSelected)
        screenshot(app, "collapsed-sidebar")

        app.typeKey("s", modifierFlags: [.control, .command])  // View › Show Sidebar
        XCTAssertTrue(rail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.outlines.firstMatch.staticTexts["Website Redesign"].exists)
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
