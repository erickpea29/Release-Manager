import Foundation
import Testing

@testable import RelvoraMCP

private let key = "test-key-0123456789"
private let echo = MCPTool(
    name: "echo", title: "Echo", description: "Returns its arguments.",
    inputSchema: ["type": "object"], isReadOnly: true
) { arguments in .success(.object(arguments)) }
private let server = MCPServer(
    name: "relvora", title: "Relvora", version: "1.0.0", instructions: "Test.", tools: [echo])
private let endpoint = MCPEndpoint(server: server, port: 4242, accessKey: key)

private func post(
    _ body: JSONValue, host: String = "127.0.0.1:4242", headers: [String: String] = [:]
) async -> HTTPResponse {
    var all = ["Host": host, "Authorization": "Bearer \(key)", "Content-Type": "application/json"]
    all.merge(headers) { _, new in new }
    return await endpoint.respond(to: HTTPRequest(method: "POST", path: "/mcp", headers: all, body: body.encoded()))
}

private func json(_ response: HTTPResponse) throws -> JSONValue { try JSONValue.parse(response.body) }

@Suite("MCP endpoint")
struct MCPEndpointTests {
    @Test("Initialize agrees on a protocol version and describes the server")
    func initialize() async throws {
        let response = await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code"]],
        ])
        #expect(response.status == 200 && response.headers["Content-Type"] == "application/json")
        let result = try #require(try json(response)["result"])
        #expect(try json(response)["id"] == 1)
        #expect(result["protocolVersion"] == "2025-03-26")
        #expect(result["serverInfo"]?["name"] == "relvora" && result["instructions"] == "Test.")
        #expect(result["capabilities"]?["tools"] != nil)
        // A version it doesn't know: the newest it supports.
        let newer = try json(
            await post([
                "jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "2099-01-01"],
            ]))
        #expect(newer["id"] == "a" && newer["result"]?["protocolVersion"] == .string(MCPServer.supportedVersions[0]))
    }

    @Test("Tools are listed with annotations, and called by name")
    func tools() async throws {
        let list = try json(await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tool = try #require(list["result"]?["tools"]?.arrayValue?.first)
        #expect(tool["name"] == "echo" && tool["annotations"]?["readOnlyHint"] == true)
        #expect(tool["annotations"]?["destructiveHint"] == false)

        let call = try json(
            await post([
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": ["name": "echo", "arguments": ["word": "hi"]],
            ]))
        let result = try #require(call["result"])
        #expect(result["isError"] == false && result["structuredContent"] == ["word": "hi"])
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONValue.parse(Data(text.utf8)) == ["word": "hi"])

        let unknown = try json(
            await post(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "delete_everything"]]))
        #expect(unknown["error"]?["code"] == -32602)
    }

    @Test("Notifications are accepted without an answer; unknown methods are errors; batches work")
    func messages() async throws {
        let notification = await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notification.status == 202 && notification.body.isEmpty)
        #expect(
            try json(await post(["jsonrpc": "2.0", "id": 5, "method": "resources/list"]))["error"]?["code"] == -32601)
        #expect(try json(await post(["jsonrpc": "2.0", "id": 6, "method": "ping"]))["result"] == [:])
        let batch = try json(
            await post([
                ["jsonrpc": "2.0", "id": 7, "method": "ping"],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ]))
        #expect(batch.arrayValue?.count == 1)
        let garbage = await endpoint.respond(
            to: HTTPRequest(
                method: "POST", path: "/mcp",
                headers: ["Host": "127.0.0.1:4242", "Authorization": "Bearer \(key)"], body: Data("{".utf8)))
        #expect(garbage.status == 400 && (try? json(garbage)["error"]?["code"]) == -32700)
    }

    @Test(
        "Requests from web pages, other hosts, or without the key are refused",
        arguments: [
            ("another host (DNS rebinding)", ["Host": "attacker.example:4242"], 403),
            ("another port", ["Host": "127.0.0.1:80"], 403),
            ("a web page", ["Origin": "https://example.com"], 403),
            ("no key", ["Authorization": ""], 401),
            ("a wrong key", ["Authorization": "Bearer test-key-0123456780"], 401),
            ("a longer key", ["Authorization": "Bearer \(key)0"], 401),
            ("an unknown protocol version", ["MCP-Protocol-Version": "1999-01-01"], 400),
            ("not JSON", ["Content-Type": "text/html"], 415),
        ])
    func refused(case: String, headers: [String: String], status: Int) async {
        var all = headers
        let host = all.removeValue(forKey: "Host") ?? "127.0.0.1:4242"
        let response = await post(["jsonrpc": "2.0", "id": 1, "method": "ping"], host: host, headers: all)
        #expect(response.status == status)
    }

    @Test("Only POST to /mcp")
    func routes() async {
        let headers = ["Host": "localhost:4242", "Authorization": "Bearer \(key)"]
        #expect(await endpoint.respond(to: HTTPRequest(method: "GET", path: "/mcp", headers: headers)).status == 405)
        #expect(await endpoint.respond(to: HTTPRequest(method: "POST", path: "/", headers: headers)).status == 404)
    }
}

@Suite("HTTP")
struct HTTPTests {
    @Test("A request with a body is parsed once it has fully arrived")
    func parse() throws {
        let raw = Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        guard case .complete(let request) = HTTPRequest.parse(raw) else {
            Issue.record("Expected a request")
            return
        }
        #expect(request.method == "POST" && request.path == "/mcp" && request.headers["host"] == "127.0.0.1:1")
        #expect(request.body == Data("abcd".utf8))
        #expect(HTTPRequest.parse(raw.dropLast()) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
    }

    @Test("Malformed, chunked, and oversized requests are refused")
    func invalid() {
        #expect(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(
            HTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
                == .invalid(status: 411))
        #expect(
            HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .invalid(status: 413)
        )
        #expect(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nA: 1\r\nA: 2\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(
            HTTPRequest.parse(Data(repeating: 65, count: HTTPRequest.maximumHeaderSize + 1)) == .invalid(status: 431))
    }

    @Test("Responses carry their length and close the connection")
    func serialize() {
        let text = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 11\r\n") && text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}

@Suite("Loopback server")
struct LoopbackServerTests {
    @Test("An MCP client on this Mac gets answers over HTTP")
    func roundTrip() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        // The port is known once the server is ready; the endpoint takes it from the request.
        let http = LoopbackServer(port: 0) { request in
            let port = UInt16(request.headers["host"]?.split(separator: ":").last ?? "") ?? 0
            return await MCPEndpoint(server: server, port: port, accessKey: key).respond(to: request)
        }
        http.start { state in
            if case .ready(let port) = state { ready.continuation.yield(port) }
        }
        defer { http.stop() }
        var iterator = ready.stream.makeAsyncIterator()
        let port = try #require(await iterator.next())

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = (["jsonrpc": "2.0", "id": 1, "method": "tools/list"] as JSONValue).encoded()
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONValue.parse(data)["result"]?["tools"]?.arrayValue?.first?["name"] == "echo")
    }
}

@Suite("Access key")
struct AccessKeyTests {
    @Test("Keys are random, URL-safe, and recognizable")
    func generate() {
        let keys = (1...20).map { _ in AccessKey.generate() }
        #expect(Set(keys).count == 20)
        #expect(keys.allSatisfy { AccessKey.isWellFormed($0) && $0.count == 47 })
        #expect(
            !AccessKey.isWellFormed("rlv_short")
                && !AccessKey.isWellFormed("rlv_" + String(repeating: "a", count: 40) + "\""))
    }
}
