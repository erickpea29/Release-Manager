import Foundation

public struct RateLimit: Sendable, Equatable {
    public let limit: Int?
    public let remaining: Int?
    public let reset: Date?
    public let resource: String?
    public let retryAfter: Int?

    init(headers: HTTPURLResponse) {
        func int(_ name: String) -> Int? { headers.value(forHTTPHeaderField: name).flatMap { Int($0) } }
        limit = int("x-ratelimit-limit")
        remaining = int("x-ratelimit-remaining")
        reset = int("x-ratelimit-reset").map { Date(timeIntervalSince1970: TimeInterval($0)) }
        resource = headers.value(forHTTPHeaderField: "x-ratelimit-resource")
        retryAfter = int("retry-after")
    }
}

public enum GitHubAPIError: Error, Equatable {
    /// Token expired, revoked, or malformed. Requires re-authorization.
    case unauthorized
    /// Authenticated, but the app/user lacks a permission. GitHub names the needed one in a header.
    case forbidden(acceptedPermissions: String?)
    case rateLimited(reset: Date?, retryAfter: Int?)
    /// Also returned for private resources the token cannot see.
    case notFound
    case conflict
    case validationFailed
    case server(status: Int)
    case unexpected(status: Int)

    public static func classify(_ response: HTTPURLResponse) -> GitHubAPIError? {
        let rate = RateLimit(headers: response)
        switch response.statusCode {
        case 200..<300, 304: return nil
        case 401: return .unauthorized
        case 403 where rate.remaining == 0 || rate.retryAfter != nil, 429:
            return .rateLimited(reset: rate.reset, retryAfter: rate.retryAfter)
        case 403: return .forbidden(acceptedPermissions: response.value(forHTTPHeaderField: "x-accepted-github-permissions"))
        case 404: return .notFound
        case 409: return .conflict
        case 422: return .validationFailed
        case 500..<600: return .server(status: response.statusCode)
        default: return .unexpected(status: response.statusCode)
        }
    }
}

public struct ProbeResult: Sendable {
    public let method: String
    public let path: String
    public let status: Int
    public let acceptedPermissions: String?
    public let rateLimit: RateLimit
    public let nextPage: URL?
    public let body: Data
    public let error: GitHubAPIError?
}

/// Minimal REST client used only to observe status codes, permission headers, and rate limits.
public struct GitHubRESTProbe: Sendable {
    public static let apiVersion = "2022-11-28"

    private let token: Secret
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(token: Secret, transport: any HTTPTransport = URLSessionTransport(), baseURL: URL = URL(string: "https://api.github.com")!) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> ProbeResult {
        try await send("GET", path, query: query, json: nil)
    }

    public func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]?) async throws -> ProbeResult {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token.rawValue)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await transport.send(request)
        return ProbeResult(
            method: method,
            path: path,
            status: response.statusCode,
            acceptedPermissions: response.value(forHTTPHeaderField: "x-accepted-github-permissions"),
            rateLimit: RateLimit(headers: response),
            nextPage: LinkHeader.next(in: response.value(forHTTPHeaderField: "Link")),
            body: data,
            error: GitHubAPIError.classify(response)
        )
    }
}

public enum LinkHeader {
    /// Parses RFC 8288 `Link` headers as GitHub sends them: `<url>; rel="next", <url>; rel="last"`.
    public static func next(in header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2,
                  segments.dropFirst().contains(where: { $0 == #"rel="next""# }),
                  segments[0].hasPrefix("<"), segments[0].hasSuffix(">") else { continue }
            return URL(string: String(segments[0].dropFirst().dropLast()))
        }
        return nil
    }
}
