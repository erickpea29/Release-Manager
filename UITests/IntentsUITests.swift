import XCTest

/// Spotlight and Shortcuts can't be driven from a UI test (ADR 0023). These drive what Relvora does with a clicked
/// Spotlight result, through a Debug launch option: the task's project opens on the tab that shows the task, with its
/// editor.
@MainActor
final class IntentsUITests: XCTestCase {
    func testASpotlightResultOpensTheTaskOnTheBoard() {
        let app = RelvoraApp.launch(["-RelvoraOpenSearchResult", "task:Fix column header truncation"])
        let editor = app.sheets.firstMatch.wait(20)
        XCTAssertEqual(editor.textFields.firstMatch.value as? String, "Fix column header truncation")
        screenshot(app, "spotlight-task-on-board")
        app.typeKey(.escape, modifierFlags: [])
        app.descendants(matching: .any)["column-To Do"].wait()
    }

    func testABacklogTaskOpensInTheBacklog() {
        let app = RelvoraApp.launch(["-RelvoraOpenSearchResult", "task:GitHub repository browser"])
        let editor = app.sheets.firstMatch.wait(20)
        XCTAssertEqual(editor.textFields.firstMatch.value as? String, "GitHub repository browser")
        app.typeKey(.escape, modifierFlags: [])
        app.descendants(matching: .any)["backlog"].wait()
    }
}
