import XCTest

/// Claude's connection (ADR 0018): the test plays Claude Code, sending MCP requests to the app on 127.0.0.1, and checks
/// the tasks appear on the open Board and in Settings.
@MainActor
final class ClaudeUITests: XCTestCase {
    private let port = 47_911
    private let key = "rlv_UITestKey_abcdefghijklmnopqrstuvwxyz0123"

    func testTasksClaudeCreatesAppearOnTheBoard() async throws {
        let app = RelvoraApp.launchProject(
            tab: "board", ["-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key])
        app.text("Release plan editor").wait(20)

        let result = try await call(
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

    func testRequestsWithoutTheKeyAreRefused() async throws {
        let app = RelvoraApp.launch(["-RelvoraClaudePort", String(port), "-RelvoraClaudeKey", key])
        app.staticTexts["Dashboard"].firstMatch.wait()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let status = try await send(request).status
        XCTAssertEqual(status, 401)
    }

    // MARK: Claude's side

    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
        ])
        let (data, status) = try await send(request)
        XCTAssertEqual(status, 200)
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return reply?["result"] as? [String: Any] ?? [:]
    }

    /// The server starts just after launch: retries until it answers.
    private func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        for attempt in 1...20 {
            if let reply = try? await URLSession(configuration: .ephemeral).data(for: request) {
                return (reply.0, (reply.1 as? HTTPURLResponse)?.statusCode ?? 0)
            }
            if attempt < 20 { try await Task.sleep(for: .milliseconds(500)) }
        }
        throw URLError(.cannotConnectToHost)
    }
}
