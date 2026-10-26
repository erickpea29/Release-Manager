import Foundation

/// An HTTP/1.1 request, as much of it as the MCP endpoint needs.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// The path without the query.
    public var path: String
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        self.body = body
    }

    public enum ParseResult: Sendable, Equatable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int)
    }

    public static let maximumHeaderSize = 16 << 10
    public static let maximumBodySize = 1 << 20

    /// Parses a request with a `Content-Length` body (or none). Chunked bodies are refused: the MCP clients send
    /// JSON with a length.
    public static func parse(_ data: Data) -> ParseResult {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderSize ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound <= maximumHeaderSize,
            let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .invalid(status: 431) }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else { return .invalid(status: 400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 411) }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid(status: 400) }
        guard length <= maximumBodySize else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= length else { return .incomplete }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: length)])
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body))
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: value.encoded())
    }

    public static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: headers.merging(["Content-Type": "text/plain; charset=utf-8"]) { a, _ in a },
            body: Data((message + "\n").utf8))
    }

    /// One response per connection: the server closes it after sending.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
