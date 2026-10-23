import XCTest

@MainActor
final class BoardUITests: XCTestCase {
    private func card(_ title: String, in column: XCUIElement) -> XCUIElement {
        column.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func column(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["column-\(name)"]
    }

    func testCreateProjectPlanVersionAddTaskAndMoveItWithTheKeyboard() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()

        app.typeKey("n", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch.wait()
        sheet.textFields.firstMatch.type("Keyboard Test")
        sheet.buttons["Create"].click()

        // The Board shows a version's tasks, so a new project's Board offers to plan one first.
        app.text("No Version in Progress").wait()
        app.buttons["New Release Plan…"].click()
        let plan = app.sheets.firstMatch.wait()
        plan.textFields.firstMatch.type("1.0.0")
        plan.buttons["Create Plan"].click()

        let toDo = column("To Do", in: app).wait()
        let quickAdd = toDo.textFields.firstMatch
        quickAdd.click()
        quickAdd.type("Write UI tests\r")
        let task = card("Write UI tests", in: toDo).wait()

        // Clicking selects the card and opens it; Escape closes the editor and leaves the board focused.
        task.click()
        app.sheets.firstMatch.wait()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        card("Write UI tests", in: column("In Progress", in: app)).wait()
        screenshot(app, "board-keyboard-move")

        app.menuBarItems["Task"].click()
        app.menuItems["Move to Previous Column"].click()
        card("Write UI tests", in: toDo).wait()

        // Return opens the selected card; the editor shows it.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.sheets.firstMatch.wait().textFields.firstMatch.value as? String, "Write UI tests")
    }

    /// The Backlog tab: tasks move into the version (and onto the Board) and back.
    func testMoveTasksBetweenTheBacklogAndTheVersion() {
        let app = RelvoraApp.launchProject(tab: "backlog")
        let backlog = app.descendants(matching: .any)["backlog"].wait()
        let row = backlog.groups["Write backup guide"].wait()
        screenshot(app, "backlog")

        row.buttons["Add to 0.2.0"].click()
        backlog.groups["Write backup guide"].buttons["Move to Backlog"].wait()

        // On the Board, in its column; its context menu sends it back.
        app.typeKey("2", modifierFlags: [.command, .option])
        let task = card("Write backup guide", in: column("To Do", in: app)).wait()
        screenshot(app, "board-with-added-task")
        task.rightClick()
        app.menuItems["Move to Backlog"].click()
        XCTAssertTrue(task.waitForNonExistence(timeout: 5))

        app.typeKey("1", modifierFlags: [.command, .option])
        backlog.groups["Write backup guide"].buttons["Add to 0.2.0"].wait()
    }
}
