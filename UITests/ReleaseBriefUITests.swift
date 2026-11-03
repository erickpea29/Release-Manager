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
