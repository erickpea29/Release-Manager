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

    /// Groups: create one, drag a project into it, move it out and back from its menu, then delete the group
    /// without deleting the project.
    func testGroupProjects() {
        let app = RelvoraApp.launch()
        let sidebar = app.outlines.firstMatch.wait()
        sidebar.staticTexts["Acme"].wait()  // the sample group
        XCTAssertTrue(sidebar.staticTexts["Other Projects"].exists)

        // Rows in a group still select their project.
        sidebar.staticTexts["Acme API"].click()
        app.text("Public REST API").wait()

        app.typeKey("n", modifierFlags: [.command, .control])  // File › New Group…
        let sheet = app.sheets.firstMatch.wait()
        sheet.textFields.firstMatch.type("Pilou")
        sheet.buttons["Create"].click()
        sidebar.staticTexts["Pilou"].wait()

        sidebar.staticTexts["Relvora"].press(forDuration: 0.5, thenDragTo: sidebar.text("No projects").wait())
        XCTAssertTrue(sidebar.staticTexts["Other Projects"].waitForNonExistence(timeout: 5))
        screenshot(app, "project-groups")

        sidebar.staticTexts["Relvora"].rightClick()
        app.menuItems["Move to Group"].click()
        app.menuItems["No Group"].click()
        sidebar.staticTexts["Other Projects"].wait()

        sidebar.staticTexts["Relvora"].rightClick()
        app.menuItems["Move to Group"].click()
        app.menuItems["Pilou"].click()
        XCTAssertTrue(sidebar.staticTexts["Other Projects"].waitForNonExistence(timeout: 5))

        sidebar.staticTexts["Pilou"].rightClick()
        app.menuItems["Delete Group…"].click()
        app.windows["main"].buttons["Delete Group"].wait().click()  // not the Touch Bar copy
        sidebar.staticTexts["Other Projects"].wait()
        XCTAssertTrue(sidebar.staticTexts["Relvora"].exists)
        XCTAssertFalse(sidebar.staticTexts["Pilou"].exists)
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
