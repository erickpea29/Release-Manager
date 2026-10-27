import AppKit
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
        app.descendants(matching: .any)["column-To Do"].wait()
        try audit(app)
    }

    func testBacklogPassesAccessibilityAudit() throws {
        let app = RelvoraApp.launchProject(tab: "backlog")
        app.descendants(matching: .any)["backlog"].wait()
        app.text("Write backup guide").wait()
        try audit(app)
    }

    func testReleasePlanPassesAccessibilityAudit() throws {
        let app = RelvoraApp.launchProject(tab: "releases", ["-RelvoraDemoScenario", "prepare"])
        app.buttons["Create GitHub Draft…"].wait(20)
        try audit(app)
    }
}

@MainActor
extension XCTestCase {
    /// Runs the audit and attaches every finding with its element, so failures say exactly what to fix.
    /// Known platform behavior is accepted (docs/DESIGN_SYSTEM.md §6):
    /// - SwiftUI pickers and menus expose "show menu" rather than "press" (`action` on pop-up and menu buttons).
    /// - AppKit window, split-view, and Touch Bar containers have no description; the title bar's sidebar button
    ///   reports a parent/child mismatch.
    /// - The system secondary text color "nearly passes" at small sizes; Increase Contrast strengthens it.
    /// - Text in selected list rows uses the system selection colors (F24).
    /// - Sidebar and toolbar contrast varies with what is behind the window (system Liquid Glass chrome, F30).
    /// Contrast is audited only on Retina displays (F29).
    /// With `window`, only that window's elements count: the main window, partly behind it, has its own audits.
    func audit(_ app: XCUIApplication, window: XCUIElement? = nil) throws {
        screenshot(app, "audited-screen")
        // Text in a selected list row is drawn in the system's selection colors (white on the accent color, or dark
        // on gray when the list isn't focused). The audit flags it in both states although it measures well above
        // 4.5:1 (F24); the same text is audited normally when not selected.
        let selectedRows = app.outlines.descendants(matching: .outlineRow).matching(
            NSPredicate(format: "isSelected == true")
        ).allElementsBoundByIndex.map(\.frame)
        // Contrast is measured from rendered pixels. On a 1x display (GitHub's macOS runners) anti-aliased small text
        // reads as low contrast, even black on light gray (F29), so contrast is audited on Retina displays only.
        let isRetina = (NSScreen.main?.backingScaleFactor ?? 1) >= 2
        let types: XCUIAccessibilityAuditType = isRetina ? .all : XCUIAccessibilityAuditType.all.subtracting(.contrast)
        if !isRetina {
            let note = XCTAttachment(string: "1x display: contrast not audited here; it is audited on Retina displays.")
            note.name = "contrast-skipped"
            note.lifetime = .keepAlways
            add(note)
        }
        // The sidebar and toolbar are system chrome on Liquid Glass, drawn over whatever is behind the window, so
        // their measured contrast changes with the desktop (F30). Our content (the detail area) is fully audited.
        let sidebar = app.outlines.allElementsBoundByIndex.map(\.frame).min { $0.minX < $1.minX }
        let chrome = [sidebar, app.toolbars.firstMatch.exists ? app.toolbars.firstMatch.frame : nil].compactMap(\.self)
        let windowFrames = try window.map { try Self.frames(in: $0.snapshot()) }
        var findings: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            if Self.isAcceptedPlatformBehavior(issue) { return true }
            if let windowFrames, let element = issue.element, element.exists, !windowFrames.contains(element.frame) {
                return true
            }
            // A row scrolled out of the window has nothing on screen to measure.
            if issue.auditType == .contrast, let window, let element = issue.element, element.exists,
                !window.frame.contains(element.frame)
            {
                return true
            }
            if issue.auditType == .contrast, let element = issue.element, element.exists {
                let frame = element.frame
                if selectedRows.contains(where: { $0.contains(frame) }) { return true }
                if chrome.contains(where: { $0.intersects(frame) && $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                ) {
                    return true
                }
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

    /// The frames of an element and everything in it.
    private static func frames(in snapshot: any XCUIElementSnapshot) -> [CGRect] {
        [snapshot.frame] + snapshot.children.flatMap { frames(in: $0) }
    }
}
