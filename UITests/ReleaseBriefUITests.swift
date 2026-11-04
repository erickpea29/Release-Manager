import XCTest

/// The release brief above a planned version (ADR 0025). The demo writer stands in for Apple Intelligence, so these
/// run on any Mac, CI included; without it, the brief is Relvora's own.
@MainActor
final class ReleaseBriefUITests: XCTestCase {
    private func briefPanel(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["releaseBrief"].wait(20)
    }

    /// A written brief: the model's headline and themes (tasks grouped by progress, which Relvora's own brief never
    /// does), with Relvora's verdict and where the words came from.
    func testWrittenBriefShowsTheModelsThemes() {
        let app = RelvoraApp.launchProject(
            tab: "releases", ["-RelvoraDemoScenario", "prepare", "-RelvoraBriefWriter", "demo"])
        let brief = briefPanel(app)
        brief.text("Written on this Mac by Apple Intelligence").wait(30)
        // The scenario's last step is the GitHub check: the brief is rewritten for it.
        brief.text("0.2.0 can be drafted after a quick look").wait(30)
        brief.text("Still in Progress", exact: true).wait()
        XCTAssertTrue(brief.text("Almost ready", exact: true).exists)
        XCTAssertTrue(brief.descendants(matching: .any)["releaseBriefNextStep"].exists)
        screenshot(app, "release-brief-written")
    }

    /// Relvora's own brief follows the plan: the checklist blocks the draft, the next step scrolls to it, and ticking
    /// its steps changes the verdict.
    func testNextStepGoesToWhatBlocksTheDraft() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "checklist"])
        let brief = briefPanel(app)
        let next = brief.descendants(matching: .any)["releaseBriefNextStep"]
        next.buttons["Go to Checklist"].wait(30).click()
        XCTAssertTrue(brief.text("Not ready yet", exact: true).exists)
        screenshot(app, "release-brief-blocked")

        for step in ["Update the screenshots", "Tell support what changed"] {
            app.checkBoxes[step].wait().click()
        }
        brief.text("Almost ready", exact: true).wait(10)
        XCTAssertFalse(next.buttons["Go to Checklist"].exists)
    }

    /// What's in the release: the model's title, the commits since the last release with the merged branch on its own
    /// lane, the release's branch and the last release named, open pull requests waiting above, and the release's size.
    func testReleaseContentsShowsTheGraphSinceTheLastRelease() {
        let app = RelvoraApp.launchProject(
            tab: "releases", ["-RelvoraDemoScenario", "prepare", "-RelvoraBriefWriter", "demo"])
        let card = app.descendants(matching: .any)["releaseChanges"].wait(30)
        card.text("perf: Faster board rendering").wait(30)
        card.text("Drafts from release plans, and a faster board").wait(30)
        card.text("7 commits since v0.1.0").wait()
        // The demo's #14 was a merge: its branch commit is listed, named after the branch.
        XCTAssertTrue(card.text("Create GitHub drafts from release plans").exists)
        XCTAssertTrue(card.text("drafts", exact: true).exists)
        XCTAssertTrue(card.text("Last release").exists)
        XCTAssertEqual(card.descendants(matching: .any).matching(identifier: "commitRow").count, 7)
        // Open pull requests into main wait above the commits; the draft one isn't listed.
        let pending = card.descendants(matching: .any).matching(identifier: "pendingPullRequestRow")
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(card.text("557 lines added and 73 removed").exists)
        screenshot(app, "release-contents")
    }

    /// GitHub work shows step by step: the scenario's check finished, then a check while offline shows the step that
    /// failed and why.
    func testLiveStepsShowWhatFailed() {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        let create = app.buttons["Create GitHub Draft…"].wait(20)
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: create)], timeout: 20)
        let activity = app.descendants(matching: .any)["releaseActivity"].wait()
        activity.text("Checked GitHub").wait()

        app.menuBarItems["Demo GitHub"].click()
        app.menuItems["Go Offline"].click()
        app.buttons["Check on GitHub"].click()
        activity.text("Couldn’t check GitHub").wait(20)
        XCTAssertTrue(activity.text("Checking tags, releases, and the version on GitHub").exists)
        XCTAssertTrue(activity.text("offline").exists)
        screenshot(app, "release-activity-failed")
    }

    /// Turning briefs off in Settings shows Relvora's own brief right away: the tasks grouped by type.
    func testTurningBriefsOffInSettings() {
        let app = RelvoraApp.launchProject(
            tab: "releases", ["-RelvoraDemoScenario", "prepare", "-RelvoraBriefWriter", "demo"])
        let brief = briefPanel(app)
        brief.text("Still in Progress", exact: true).wait(30)

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Releases"].wait().click()
        app.descendants(matching: .any)["writesReleaseBriefs"].wait().click()
        screenshot(app, "settings-releases")
        app.typeKey("w", modifierFlags: .command)

        brief.text("Bug Fixes", exact: true).wait(10)
        XCTAssertFalse(brief.text("Still in Progress", exact: true).exists)
        XCTAssertFalse(brief.text("Written on this Mac").exists)
    }
}
