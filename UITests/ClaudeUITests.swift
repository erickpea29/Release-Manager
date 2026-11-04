import XCTest

/// Claude's connection (ADR 0018, ADR 0026): the test plays Claude Code, sending MCP requests to the app on 127.0.0.1,
/// and checks what Claude does shows on the open Board and in Settings.
@MainActor
final class ClaudeUITests: XCTestCase {
    private let port = 47_911
    private let key = "rlv_UITestKey_abcdefghijklmnopqrstuvwxyz0123"

    func testTasksClaudeCreatesAppearOnTheBoard() async throws {
        let app = RelvoraApp.launchProject(
            tab: "board", ["-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key])
        app.text("Release plan editor").wait(20)

        let result = try await MCPTestClient(port: port, key: key).call(
            "create_tasks",
            [
                "project": "Relvora",
                "tasks": [["title": "Task from Claude", "type": "bugFix", "checklist": ["Reproduce", "Fix"]]],
            ])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        // A card is one element for VoiceOver: title, priority, type, labels, checklist.
        let card = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Task from Claude,' AND label CONTAINS 'Labels: claude'"))
        card.firstMatch.wait(10)
        XCTAssertTrue(card.firstMatch.label.contains("Checklist 0 of 2"))
        screenshot(app, "claude-task-on-board")

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Claude"].wait().click()
        XCTAssertEqual(app.switches["claudeEnabled"].wait().value as? Int, 1)
        app.text("Running on 127.0.0.1:\(port)").wait()
        app.text("Claude added 1 task to Relvora").wait()
        XCTAssertTrue(app.buttons["Copy Setup Command"].exists)
        screenshot(app, "settings-claude")
    }

    func testClaudeEditsCompletesAndDeletesTasksOnTheBoard() async throws {
        let app = RelvoraApp.launchProject(
            tab: "board", ["-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key])
        let doomed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Release plan editor,'")).firstMatch
        doomed.wait(20)
        let claude = MCPTestClient(port: port, key: key)

        let created = try await claude.call("create_tasks", ["project": "Relvora", "tasks": [["title": "Draft"]]])
        let id = try XCTUnwrap(Self.structured(created)?["created"]?.first?["id"] as? String, "\(created)")
        let updated = try await claude.call(
            "update_tasks",
            ["project": "Relvora", "tasks": [["id": id, "title": "Finished by Claude", "priority": "urgent", "done": true]]])
        XCTAssertEqual(updated["isError"] as? Bool, false, "\(updated)")
        // In the Done column, done, with its new title and priority.
        let done = app.descendants(matching: .any)["column-Done"].buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Finished by Claude, Urgent priority,' AND label CONTAINS 'Done'"))
        done.firstMatch.wait(10)

        let listed = try await claude.call("list_tasks", ["project": "Relvora"])
        let tasks = Self.structured(listed)?["tasks"] ?? []
        let doomedID = try XCTUnwrap(tasks.first { $0["title"] as? String == "Release plan editor" }?["id"] as? String)
        let deleted = try await claude.call("delete_tasks", ["project": "Relvora", "ids": [doomedID]])
        XCTAssertEqual(deleted["isError"] as? Bool, false, "\(deleted)")
        XCTAssertTrue(doomed.waitForNonExistence(timeout: 10))
        screenshot(app, "claude-edits-board")

        app.typeKey(",", modifierFlags: .command)
        app.toolbars.buttons["Claude"].wait().click()
        app.text("Claude deleted “Release plan editor” from Relvora.").wait()
        app.text("Claude updated “Finished by Claude” in Relvora.").wait()
        screenshot(app, "settings-claude-activity")
    }

    /// A tool result's JSON: lists of objects by key.
    private static func structured(_ result: [String: Any]) -> [String: [[String: Any]]]? {
        (result["structuredContent"] as? [String: Any])?.compactMapValues { $0 as? [[String: Any]] }
    }

    func testRequestsWithoutTheKeyAreRefused() async throws {
        let app = RelvoraApp.launch(["-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key])
        app.staticTexts["Dashboard"].firstMatch.wait()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let status = try await MCPTestClient.send(request).status
        XCTAssertEqual(status, 401)
    }
}
