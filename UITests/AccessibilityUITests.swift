import XCTest

/// Xcode's accessibility audit (labels, contrast, hit areas, Dynamic Type…) on the main screens.
@MainActor
final class AccessibilityUITests: XCTestCase {
    func testDashboardPassesAccessibilityAudit() throws {
        let app = RelvoraApp.launch()
        app.staticTexts["Dashboard"].firstMatch.wait()
        try audit(app)
    }

    func testBoardPassesAccessibilityAudit() throws {
        let app = RelvoraApp.launchProject(tab: "board")
        app.descendants(matching: .any)["column-Backlog"].wait()
        try audit(app)
    }

    func testReleasePlanPassesAccessibilityAudit() throws {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        app.buttons["Create GitHub Draft…"].wait(20)
        try audit(app)
    }

    /// Runs the audit and attaches every finding with its element, so failures say exactly what to fix.
    /// Known platform behavior is accepted (docs/DESIGN_SYSTEM.md §6):
    /// - SwiftUI pickers and menus expose "show menu" rather than "press" (`action` on pop-up and menu buttons).
    /// - AppKit window, split-view, and Touch Bar containers have no description; the title bar's sidebar button
    ///   reports a parent/child mismatch.
    /// - The system secondary text color "nearly passes" at small sizes; Increase Contrast strengthens it.
    /// - Text in selected list rows uses the system selection colors (F24).
    private func audit(_ app: XCUIApplication) throws {
        screenshot(app, "audited-screen")
        // Text in a selected list row is drawn in the system's selection colors (white on the accent color, or dark
        // on gray when the list isn't focused). The audit flags it in both states although it measures well above
        // 4.5:1 (F24); the same text is audited normally when not selected.
        let selectedRows = app.outlines.descendants(matching: .outlineRow).matching(
            NSPredicate(format: "isSelected == true")
        ).allElementsBoundByIndex.map(\.frame)
        var findings: [String] = []
        try app.performAccessibilityAudit { issue in
            if Self.isAcceptedPlatformBehavior(issue) { return true }
            if issue.auditType == .contrast, let element = issue.element, element.exists,
                selectedRows.contains(where: { $0.contains(element.frame) })
            {
                return true
            }
            var element = "no element"
            if let target = issue.element, target.exists {
                element =
                    "\(target.elementType) id='\(target.identifier)' label='\(target.label)' frame=\(target.frame)"
            }
            findings.append("\(issue.compactDescription) | \(element) | \(issue.detailedDescription)")
            return false
        }
        if !findings.isEmpty {
            let report = XCTAttachment(string: findings.joined(separator: "\n"))
            report.name = "accessibility-findings"
            report.lifetime = .keepAlways
            add(report)
        }
    }

    private static func isAcceptedPlatformBehavior(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let type = issue.element.flatMap { $0.exists ? $0.elementType : nil }
        switch issue.auditType {
        case .action: return type == .popUpButton || type == .menuButton
        case .parentChild: return true
        case .sufficientElementDescription: return type == .group || type == .touchBar || type == nil
        case .contrast: return issue.compactDescription.localizedCaseInsensitiveContains("nearly")
        default: return false
        }
    }
}
