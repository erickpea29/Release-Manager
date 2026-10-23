import XCTest

/// The release workflow against the in-memory demo GitHub: nothing is sent to github.com.
@MainActor
final class ReleaseWorkflowUITests: XCTestCase {
    func testDraftPublicationAndHistory() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        let notes = app.textViews.firstMatch.wait(20)
        let generated = expectation(for: NSPredicate(format: "value CONTAINS 'Bug Fixes'"), evaluatedWith: notes)
        wait(for: [generated], timeout: 20)

        let create = app.buttons["Create GitHub Draft…"].wait()
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)
        wait(for: [enabled], timeout: 20)
        create.click()

        let sheet = app.sheets.firstMatch.wait(20)
        XCTAssertFalse(sheet.buttons["Create Draft"].isEnabled, "Incomplete tasks must be confirmed first")
        screenshot(app, "release-review")
        sheet.checkBoxes.firstMatch.click()
        sheet.buttons["Create Draft"].click()

        app.text("Draft on GitHub", exact: true).wait(20)
        app.menuBarItems["Demo GitHub"].click()
        app.menuItems["Publish Drafts on Demo GitHub"].click()
        app.buttons["Check Publication"].click()
        app.text("Published on GitHub", exact: true).wait(20)
        screenshot(app, "release-published")

        app.buttons["Show in Release History"].click()
        app.text("Published on GitHub, with the tag verified at the recorded commit.").wait()
        screenshot(app, "release-history")
    }

    /// Publishing from Relvora: the confirmation shows the draft as GitHub has it, and the publication is verified.
    func testPublishTheDraftFromRelvora() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "draft"])
        app.text("Draft on GitHub", exact: true).wait(30)
        app.buttons["Publish Release…"].click()

        let sheet = app.sheets.firstMatch.wait(20)
        sheet.text("New. GitHub creates it at this commit.").wait()
        screenshot(app, "publish-confirmation")
        sheet.buttons["Publish Release"].click()

        app.text("Published on GitHub", exact: true).wait(20)
        XCTAssertTrue(app.text("Verified:").exists)
        screenshot(app, "published-from-relvora")
    }

    func testTimeoutNeedsReconciliationAndCheckGitHubLinksTheDraft() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "timeout"])
        let check = app.buttons["Check GitHub"].wait(30)
        XCTAssertTrue(app.text("Needs reconciliation").exists)
        screenshot(app, "release-timeout")
        check.click()
        app.text("Found the draft on GitHub and linked it").wait(20)
        app.text("Draft on GitHub", exact: true).wait()
    }
}
