import Foundation

/// A credential that cannot leak through `print`, interpolation, `dump`, or debugger summaries.
/// It is `Codable` only so the token set can be written to the Keychain.
public struct Secret: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Ephemeral and cache-less: auth responses and private payloads never land in URLCache on disk.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

enum FormEncoding {
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encode(_ parameters: [(String, String)]) -> Data {
        Data(
            parameters.map { key, value in "\(escape(key))=\(escape(value))" }
                .joined(separator: "&")
                .utf8)
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum LinkHeader {
    /// The `rel="next"` URL of an RFC 8288 `Link` header, as GitHub sends it.
    static func next(in header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments.dropFirst().contains(#"rel="next""#),
                segments[0].hasPrefix("<"), segments[0].hasSuffix(">")
            else { continue }
            return URL(string: String(segments[0].dropFirst().dropLast()))
        }
        return nil
    }
}
