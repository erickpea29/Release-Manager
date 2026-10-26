import Foundation

/// MCP's Streamable HTTP transport on this Mac only, at `POST /mcp` (ADR 0018). Before the server sees a message:
///
/// - The `Host` must be this Mac's loopback address and port. A web page that renames its domain to 127.0.0.1 (DNS
///   rebinding) still sends its own host name.
/// - Requests with an `Origin` are refused: browsers send one, command-line clients such as Claude Code don't.
/// - The `Authorization` header must carry the access key, compared in constant time.
///
/// Answers are plain JSON; the server never streams or starts a session.
public struct MCPEndpoint: Sendable {
    public static let path = "/mcp"

    private let server: MCPServer
    private let port: UInt16
    private let accessKey: String

    public init(server: MCPServer, port: UInt16, accessKey: String) {
        self.server = server
        self.port = port
        self.accessKey = accessKey
    }

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.path == Self.path else { return .text(404, "Not found") }
        guard let host = request.headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host) else {
            return .text(403, "Relvora answers only on 127.0.0.1:\(port).")
        }
        guard request.headers["origin"] == nil else {
            return .text(403, "Relvora doesn't answer requests from web pages.")
        }
        guard Self.matches(request.headers["authorization"], "Bearer " + accessKey) else {
            return .text(
                401, "A valid access key is needed. Copy the setup command from Relvora's Settings.",
                headers: ["WWW-Authenticate": "Bearer"])
        }
        guard request.method == "POST" else { return .text(405, "Use POST.", headers: ["Allow": "POST"]) }
        if let version = request.headers["mcp-protocol-version"], !MCPServer.supportedVersions.contains(version) {
            return .text(400, "Unsupported MCP protocol version \(version).")
        }
        if let type = request.headers["content-type"], !type.lowercased().hasPrefix("application/json") {
            return .text(415, "Send JSON.")
        }
        guard let message = try? JSONValue.parse(request.body) else {
            return .json(MCPServer.error(id: .null, code: -32700, "Parse error"), status: 400)
        }
        guard let reply = await server.handle(message) else { return HTTPResponse(status: 202) }
        return .json(reply)
    }

    /// Constant-time comparison, so the key can't be guessed from response times.
    static func matches(_ given: String?, _ expected: String) -> Bool {
        let given = Array((given ?? "").utf8)
        let expected = Array(expected.utf8)
        var difference = UInt8(given.count == expected.count ? 0 : 1)
        for index in expected.indices {
            difference |= expected[index] ^ (index < given.count ? given[index] : 0)
        }
        return difference == 0
    }
}
