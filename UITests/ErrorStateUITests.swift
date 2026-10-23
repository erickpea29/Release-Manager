import XCTest

@MainActor
final class ErrorStateUITests: XCTestCase {
    func testOfflineRefreshKeepsCachedRepositoryData() {
        let app = RelvoraApp.launchProject(tab: "github")
        app.text("relvora-demo/relvora").wait(20)
        app.text("Synced").wait(20)
        XCTAssertTrue(app.text("refreshes every 5 minutes").exists, "Automatic refresh is on by default")

        app.menuBarItems["Demo GitHub"].click()
        app.menuItems["Go Offline"].click()
        app.buttons["Refresh"].click()

        app.text("Couldn’t refresh. Showing cached data").wait(20)
        XCTAssertTrue(app.text("You’re offline").exists)
        screenshot(app, "github-offline")
    }

    func testOfflineReleaseCheckExplainsTheProblem() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        let notes = app.textViews.firstMatch.wait(20)
        let generated = expectation(for: NSPredicate(format: "value CONTAINS 'Bug Fixes'"), evaluatedWith: notes)
        wait(for: [generated], timeout: 20)

        app.menuBarItems["Demo GitHub"].click()
        app.menuItems["Go Offline"].click()
        app.buttons["Check on GitHub"].click()
        app.text("You’re offline").wait(20)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Nothing may be created while offline")
    }
}
