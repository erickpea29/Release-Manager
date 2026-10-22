import XCTest

/// Launches Relvora for a UI test: a throwaway in-memory store with sample data, the in-memory demo GitHub, and a
/// separate settings suite, so tests are independent, offline, and never touch real data, settings, or GitHub.
@MainActor
enum RelvoraApp {
    static func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            [
                "-RelvoraInMemoryStore", "YES",
                "-RelvoraSeedSampleData", "YES",
                "-RelvoraDemoGitHub", "YES",
                "-RelvoraDefaultsSuite", "com.erickpea29.Relvora.UITests",
                "-NSQuitAlwaysKeepsWindows", "NO",
                "-ApplePersistenceIgnoreState", "YES",
            ] + extra
        app.launch()
        return app
    }

    /// Opens the sample "Relvora" project on a tab, connected to the demo repository.
    static func launchProject(tab: String, _ extra: [String] = []) -> XCUIApplication {
        launch(
            [
                "-RelvoraInitialProject", "Relvora", "-RelvoraInitialTab", tab,
                "-RelvoraConnectRepository", "relvora-demo/relvora",
            ] + extra)
    }
}

extension XCUIElement {
    /// Types text, sending real Space key presses: on macOS 26, `typeText` drops spaces in SwiftUI text fields (F23).
    @MainActor
    func type(_ text: String) {
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { typeKey(.space, modifierFlags: []) }
            if !word.isEmpty { typeText(String(word)) }
        }
    }

    /// Any text on screen: static texts by value or label, other elements by label.
    @MainActor
    func text(_ text: String, exact: Bool = false) -> XCUIElement {
        let operation = exact ? "==" : "CONTAINS"
        let predicate = NSPredicate(
            format: "(elementType == %@ AND value \(operation) %@) OR label \(operation) %@",
            NSNumber(value: XCUIElement.ElementType.staticText.rawValue), text, text)
        return descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Waits for the element and fails the test with a clear message if it never appears.
    @MainActor
    @discardableResult
    func wait(_ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = waitForExistence(timeout: timeout)
        if !found {
            // The accessibility tree at the time of the failure, for diagnosis (in the test result).
            XCTContext.runActivity(named: "Accessibility tree after timeout") { activity in
                let tree = XCTAttachment(string: XCUIApplication().debugDescription)
                tree.name = "tree-line-\(line)"
                tree.lifetime = .keepAlways
                activity.add(tree)
            }
        }
        XCTAssertTrue(found, "Timed out waiting for \(self)", file: file, line: line)
        return self
    }
}

extension XCTestCase {
    /// Attaches a screenshot to the test result (export with `xcrun xcresulttool export attachments`).
    @MainActor
    func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
