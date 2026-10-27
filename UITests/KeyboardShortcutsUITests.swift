import XCTest

/// Help › Keyboard Shortcuts: the window, its rows as VoiceOver reads them, search, and the accessibility audit.
@MainActor
final class KeyboardShortcutsUITests: XCTestCase {
    func testHelpMenuOpensTheShortcutList() throws {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        app.menuBars.menuBarItems["Help"].click()
        app.menuItems["Keyboard Shortcuts"].wait().click()
        let window = shortcutsWindow(app).wait()

        // A menu command, a Task menu key, and board keys that aren't menu commands, read as one line each.
        expectRow(window, "newTask", "New Task", "Command N")
        expectRow(window, "newGroup", "New Group…", "Control Command N")
        expectRow(window, "moveTaskRight", "Move to Next Column", "Option Command Right Arrow")
        expectRow(window, "selectCard", "Select a card", "Arrow keys")
        expectRow(window, "openCard", "Open the selected card", "Return or Space")
        screenshot(app, "keyboard-shortcuts")
        try audit(app, window: window)

        let search = window.textFields["shortcutsSearch"].wait()
        search.click()
        search.type("column")
        row(window, "moveTaskLeft").wait()
        XCTAssertTrue(row(window, "moveTaskRight").exists)
        XCTAssertFalse(row(window, "newTask").exists)
    }

    func testQuickActionsOpensTheShortcutList() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        app.typeKey("k", modifierFlags: .command)
        app.textFields["quickActionsSearch"].wait().type("keyboard shortcuts\r")
        row(shortcutsWindow(app).wait(), "quickActions").wait()
    }

    private func shortcutsWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", "Keyboard Shortcuts")).firstMatch
    }

    private func row(_ window: XCUIElement, _ command: String) -> XCUIElement {
        window.descendants(matching: .any)["shortcut-\(command)"]
    }

    private func expectRow(
        _ window: XCUIElement, _ command: String, _ title: String, _ keys: String, line: UInt = #line
    ) {
        let row = row(window, command).wait(line: line)
        XCTAssertEqual(row.label, title, line: line)
        XCTAssertEqual(row.value as? String, keys, line: line)
    }
}
