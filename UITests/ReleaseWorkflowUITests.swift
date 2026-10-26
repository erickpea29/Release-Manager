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

    /// The release checklist: steps added in the editor block the draft until each is ticked. The plan also shows that
    /// its version matches the changes.
    func testReleaseChecklistBlocksTheDraftUntilEveryStepIsTicked() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        let create = app.buttons["Create GitHub Draft…"].wait(20)
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)], timeout: 20)
        app.text("0.2.0 matches the changes").wait()

        app.buttons["Add Steps…"].click()
        let sheet = app.sheets.firstMatch.wait()
        sheet.buttons["Add Step"].click()
        sheet.textFields.firstMatch.type("Test on a clean Mac")
        sheet.buttons["Save"].click()

        let step = app.checkBoxes["Test on a clean Mac"].wait()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: create)], timeout: 10)
        app.text("isn’t done yet").wait()
        screenshot(app, "release-checklist")

        step.click()
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)], timeout: 10)
    }

    /// A new plan starts with the suggested version: a project without releases starts at 0.1.0.
    func testNewPlanStartsWithTheSuggestedVersion() {
        let app = RelvoraApp.launch(["-RelvoraInitialProject", "Website Redesign", "-RelvoraInitialTab", "releases"])
        app.buttons["New Release Plan"].firstMatch.wait().click()  // the toolbar's and the empty page's
        let sheet = app.sheets.firstMatch.wait()
        sheet.text("for the first release").wait()
        XCTAssertEqual(sheet.textFields.firstMatch.value as? String, "0.1.0")
        screenshot(app, "version-suggestion")
        sheet.buttons["Create Plan"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
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
