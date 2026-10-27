import XCTest

/// Pull requests and CI beside a release (ADR 0020), against the demo GitHub: #16's CI passed, #17's is still running,
/// and draft #18 failed. Nothing is sent to github.com.
@MainActor
final class PullRequestUITests: XCTestCase {
    /// Merging #16 from the release plan adds a commit to main. Once its CI passes, it's offered as the release's
    /// commit. "CI finishes" notifications are recorded for #17 and main, never for CI that finished before Relvora
    /// looked.
    func testMergeFromTheReleasePlanThenUseTheCommitWhoseCIPassed() {
        let app = RelvoraApp.launchProject(
            tab: "releases",
            [
                "-RelvoraDemoScenario", "prepare", "-RelvoraPullRequestCheckInterval", "2",
                "-RelvoraDemoCISeconds", "8",
            ])
        let ready = app.descendants(matching: .any)["pullRequest-16"].wait(30)
        ready.text("CI passed").wait()
        ready.text("Ready to merge").wait()
        app.descendants(matching: .any)["pullRequest-17"].text("CI running").wait()
        XCTAssertFalse(app.buttons["merge-17"].isEnabled, "Merging waits for CI")
        app.descendants(matching: .any)["pullRequest-18"].text("CI failed: UI tests").wait()
        XCTAssertFalse(app.buttons["merge-18"].isEnabled, "A draft can't be merged")
        screenshot(app, "pull-requests")

        app.buttons["merge-16"].click()
        let sheet = app.sheets.firstMatch.wait()
        sheet.text("Merge #16 into main?").wait()
        screenshot(app, "merge-confirmation")
        sheet.buttons["Merge Pull Request"].click()
        app.text("Merged #16 into main", exact: true).wait(20)
        app.descendants(matching: .any)["mergedPullRequest-16"].wait(20)

        // main's new commit runs CI; once it passes, it's offered as the release's commit (a link-style button).
        app.links["useLatestPassingCommit"].wait(40).click()
        let targetCI = app.descendants(matching: .any)["targetCommitCI"]
        let passed = NSPredicate(format: "label CONTAINS 'CI passed' OR value CONTAINS 'CI passed'")
        wait(for: [expectation(for: passed, evaluatedWith: targetCI)], timeout: 10)
        XCTAssertTrue(app.text("Merge pull request #16").exists)
        screenshot(app, "release-commit-ci")

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Notifications"].wait().click()
        app.text("#17 is ready to merge").wait(20)
        app.text("main is ready for Relvora 0.2.0").wait(20)
        let recorded = app.descendants(matching: .any).matching(identifier: "recordedNotification")
        XCTAssertEqual(
            recorded.matching(NSPredicate(format: "value CONTAINS '#18' OR value CONTAINS '#16 is ready'")).count, 0,
            "CI that finished before Relvora looked isn't announced")
        screenshot(app, "ci-notifications")
    }

    /// The GitHub tab lists pull requests into every branch, first.
    func testGitHubTabListsPullRequests() {
        let app = RelvoraApp.launchProject(tab: "github")
        let row = app.descendants(matching: .any)["pullRequest-16"].wait(30)
        row.text("feature/pull-requests → main").wait()
        row.text("CI passed").wait()
        XCTAssertTrue(app.buttons["merge-16"].isEnabled)
    }
}
