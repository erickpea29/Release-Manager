import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    func testAppearanceAccentAndWindowSettings() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        app.typeKey(",", modifierFlags: .command)
        // Settings reopens on the last tab used, which may be another test's.
        app.toolbars.buttons["General"].wait().click()

        app.radioButtons["Dark"].wait().click()
        app.buttons["Purple accent"].click()
        app.radioButtons["Translucent"].click()
        screenshot(app, "settings-general")

        app.typeKey("w", modifierFlags: .command)
        app.staticTexts["Dashboard"].firstMatch.wait()
        screenshot(app, "dashboard-dark-translucent-purple")
    }

    func testBoardTemplateAppliesToNewProjects() {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Board"].wait().click()
        app.buttons["Add Column"].wait().click()
        screenshot(app, "settings-board")
        app.typeKey("w", modifierFlags: .command)

        app.typeKey("n", modifierFlags: [.command, .shift])
        let sheet = app.sheets.firstMatch.wait()
        sheet.textFields.firstMatch.type("Template Test")
        sheet.buttons["Create"].click()
        app.descendants(matching: .any)["column-Column 6"].wait()
    }
}
