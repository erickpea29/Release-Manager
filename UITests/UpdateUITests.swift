import XCTest

/// Updating Relvora from Relvora, against the demo GitHub. The demo download isn't a signed app, so the updater
/// service refuses it and nothing is installed: the test covers the offer, the notes, the connection to the updater,
/// and the refusal.
@MainActor
final class UpdateUITests: XCTestCase {
    func testAnOfferedUpdateIsCheckedBeforeItIsInstalled() {
        let app = RelvoraApp.launch(["-RelvoraDemoUpdateVersion", "9.9.0"])
        // The automatic check runs a few seconds after launch and offers the version in the sidebar.
        app.buttons["updateAvailable"].wait(30).click()
        let sheet = app.sheets.firstMatch.wait()
        sheet.text("Relvora 9.9.0 is available").wait()
        sheet.text("Relvora updates itself").wait()
        screenshot(app, "update-available")

        // Test builds are ad-hoc signed, so the updater refuses before it unpacks anything; team-signed builds
        // refuse the placeholder zip instead. Either way the reason is shown and nothing changes.
        sheet.buttons["Install and Relaunch"].click()
        sheet.text("Relvora 9.9.0 wasn’t installed").wait(30)
        screenshot(app, "update-refused")
        sheet.buttons["Close"].click()

        // Skipped: the sidebar stops offering it, but Check for Updates still shows it.
        app.buttons["updateAvailable"].click()
        app.sheets.firstMatch.buttons["Skip This Version"].wait().click()
        XCTAssertFalse(app.buttons["updateAvailable"].waitForExistence(timeout: 2))
        app.menuBarItems["Relvora"].click()
        app.menuItems["Check for Updates…"].click()
        app.sheets.firstMatch.text("Relvora 9.9.0 is available").wait(20)
        app.sheets.firstMatch.buttons["Later"].click()
    }

    func testCheckForUpdatesWhenUpToDate() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        app.menuBarItems["Relvora"].click()
        app.menuItems["Check for Updates…"].click()
        let sheet = app.sheets.firstMatch.wait(20)
        sheet.text("Relvora is up to date").wait(20)
        sheet.buttons["OK"].click()

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["General"].wait().click()
        let automatic = app.switches["checksForUpdates"].wait()
        XCTAssertEqual(automatic.value as? Int, 1, "Automatic checks are on by default")
        XCTAssertEqual(automatic.label, "Check for updates automatically")
        app.text("Last checked").wait()
        screenshot(app, "settings-updates")
    }
}
