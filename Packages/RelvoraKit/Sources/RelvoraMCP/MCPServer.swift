import Foundation

/// A tool Claude can call.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String
    public let description: String
    /// A JSON Schema object for the arguments.
    public let inputSchema: JSONValue
    public let isReadOnly: Bool
    public let run: @Sendable (_ arguments: [String: JSONValue]) async -> MCPToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, isReadOnly: Bool,
        run: @escaping @Sendable ([String: JSONValue]) async -> MCPToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.isReadOnly = isReadOnly
        self.run = run
    }

    var listing: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title), "readOnlyHint": .bool(isReadOnly), "destructiveHint": false,
                "idempotentHint": .bool(isReadOnly), "openWorldHint": false,
            ],
        ]
    }
}

/// What a tool returns: JSON for the model to read, or an error it can act on.
public struct MCPToolResult: Sendable, Equatable {
    public let content: JSONValue
    public let isError: Bool

    public static func success(_ content: JSONValue) -> MCPToolResult {
        MCPToolResult(content: content, isError: false)
    }

    /// A problem the model can fix or explain, such as an unknown project. Not a protocol error.
    public static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(content: .string(message), isError: true)
    }

    var json: JSONValue {
        let text = content.stringValue ?? content.prettyText()
        var result: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]], "isError": .bool(isError),
        ]
        if !isError, case .object = content { result["structuredContent"] = content }
        return .object(result)
    }
}

/// The Model Context Protocol over JSON-RPC 2.0: `initialize`, `ping`, `tools/list`, and `tools/call`
/// (specification 2025-06-18, also answering clients of 2025-03-26 and 2024-11-05).
public struct MCPServer: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let title: String
    public let version: String
    public let instructions: String
    public let tools: [MCPTool]

    public init(name: String, title: String, version: String, instructions: String, tools: [MCPTool]) {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// A message or a batch of messages. `nil` when nothing needs an answer (notifications, responses).
    public func handle(_ body: JSONValue) async -> JSONValue? {
        if let batch = body.arrayValue {
            guard !batch.isEmpty else { return Self.error(id: .null, code: -32600, "Empty batch") }
            var replies: [JSONValue] = []
            for message in batch {
                if let reply = await handleOne(message) { replies.append(reply) }
            }
            return replies.isEmpty ? nil : .array(replies)
        }
        return await handleOne(body)
    }

    private func handleOne(_ message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue, object["jsonrpc"] == "2.0" else {
            return Self.error(id: .null, code: -32600, "Invalid request")
        }
        guard let method = object["method"]?.stringValue else { return nil }  // A response to us: nothing to do.
        guard let id = object["id"] else { return nil }  // A notification, such as notifications/initialized.
        let params = object["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version =
                requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            return Self.result(
                id: id,
                [
                    "protocolVersion": .string(version),
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": .string(name), "title": .string(title), "version": .string(self.version)],
                    "instructions": .string(instructions),
                ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = tools.first(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, "Unknown tool: \(params["name"]?.stringValue ?? "none")")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            return Self.result(id: id, await tool.run(arguments).json)
        default:
            return Self.error(id: id, code: -32601, "Method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .integer(code), "message": .string(message)]]
    }
}
