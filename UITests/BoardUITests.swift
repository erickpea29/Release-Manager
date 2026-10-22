import XCTest

@MainActor
final class BoardUITests: XCTestCase {
    private func card(_ title: String, in column: XCUIElement) -> XCUIElement {
        column.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func column(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["column-\(name)"]
    }

    func testCreateProjectAddTaskAndMoveItWithTheKeyboard() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()

        app.typeKey("n", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch.wait()
        sheet.textFields.firstMatch.type("Keyboard Test")
        sheet.buttons["Create"].click()

        let backlog = column("Backlog", in: app).wait()
        let quickAdd = backlog.textFields.firstMatch
        quickAdd.click()
        quickAdd.type("Write UI tests\r")
        let task = card("Write UI tests", in: backlog).wait()

        // Clicking selects the card and opens it; Escape closes the editor and leaves the board focused.
        task.click()
        app.sheets.firstMatch.wait()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        card("Write UI tests", in: column("To Do", in: app)).wait()
        screenshot(app, "board-keyboard-move")

        app.menuBarItems["Task"].click()
        app.menuItems["Move to Previous Column"].click()
        card("Write UI tests", in: backlog).wait()

        // Return opens the selected card; the editor shows it.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(app.sheets.firstMatch.wait().textFields.firstMatch.value as? String, "Write UI tests")
    }
}
