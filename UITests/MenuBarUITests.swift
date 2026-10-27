import XCTest

/// The menu bar icon (ADR 0022): versions in progress and drafts waiting, each opening its project's Releases tab, and
/// the switch in Settings › General. Relvora has one status item, so the tests use the first.
@MainActor
final class MenuBarUITests: XCTestCase {
    func testSettingsSwitchHidesAndShowsTheIcon() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        let icon = app.statusItems.firstMatch.wait()
        XCTAssertEqual(icon.label, "Relvora")

        app.typeKey(",", modifierFlags: .command)
        // Settings reopens on the last tab used, which may be another test's.
        app.toolbars.buttons["General"].wait().click()
        let toggle = app.switches["showsMenuBarIcon"].wait()
        XCTAssertEqual(toggle.value as? Int, 1)
        XCTAssertEqual(toggle.label, "Show Relvora in the menu bar")
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        XCTAssertTrue(icon.waitForNonExistence(timeout: 5))
        screenshot(app, "settings-menu-bar-off")

        toggle.click()
        app.statusItems.firstMatch.wait()
    }

    /// From the Dashboard, the version being planned opens its project's Releases tab.
    func testVersionOpensItsProjectFromTheMenuBar() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()

        app.statusItems.firstMatch.wait().click()
        let version = app.menuItems["Relvora 0.2.0"].wait()
        XCTAssertTrue(app.text("Versions in Progress", exact: true).exists)
        XCTAssertFalse(app.text("Drafts Waiting", exact: true).exists)
        XCTAssertTrue(app.menuItems["Open Relvora"].exists)
        XCTAssertTrue(app.menuItems["Quit Relvora"].exists)
        version.click()

        app.buttons["Edit Plan…"].wait()  // the plan, on the Releases tab
        XCTAssertTrue(app.text("Kanban and backups").exists)
        screenshot(app, "menu-bar-opened-version")
    }

    /// A draft waiting on GitHub is listed apart from the versions in progress, and opens its plan.
    func testDraftWaitingOpensItsPlan() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "draft"])
        app.text("Draft on GitHub", exact: true).wait(30)
        app.typeKey("1", modifierFlags: .command)  // Go › Dashboard
        app.staticTexts["Projects"].wait()

        app.statusItems.firstMatch.wait().click()
        let draft = app.menuItems["Relvora 0.2.0"].wait()
        XCTAssertTrue(app.text("Drafts Waiting", exact: true).exists)
        XCTAssertFalse(app.text("Versions in Progress", exact: true).exists)
        draft.click()

        app.text("Draft on GitHub", exact: true).wait()
    }
}
