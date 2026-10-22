import Foundation
import Synchronization

@testable import GitHubIntegration

/// A scripted GitHub: responses are queued per URL path, optionally prefixed with a method (`POST /repos/…`); the
/// last response for a route repeats.
actor MockGitHub: HTTPTransport {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = "{}"
        var offline = false
        /// Thrown instead of answering, e.g. `.timedOut` or `.networkConnectionLost`.
        var failure: URLError.Code?
        var delay: Duration = .zero
    }

    private var routes: [String: [Response]] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ path: String, _ responses: Response...) {
        routes[path, default: []] += responses
    }

    func on(_ path: String, json: String, headers: [String: String] = [:]) {
        routes[path, default: []].append(Response(headers: headers, body: json))
    }

    /// Requests to `path`, of any method unless one is given.
    func requests(to path: String, method: String? = nil) -> [URLRequest] {
        requests.filter { $0.url?.path(percentEncoded: false) == path && (method == nil || $0.httpMethod == method) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let method = request.httpMethod ?? "GET"
        let urlPath = request.url!.path(percentEncoded: false)
        // A method-specific route wins; plain paths match any method (the OAuth endpoints are POSTs).
        let path = routes["\(method) \(urlPath)"] != nil ? "\(method) \(urlPath)" : urlPath
        guard var queue = routes[path], !queue.isEmpty else {
            return (Data(#"{"message":"Not Found"}"#.utf8), Self.response(request, status: 404, headers: [:]))
        }
        let response = queue.count > 1 ? queue.removeFirst() : queue[0]
        routes[path] = queue
        if response.delay > .zero { try await Task.sleep(for: response.delay) }
        if response.offline { throw URLError(.notConnectedToInternet) }
        if let failure = response.failure { throw URLError(failure) }
        return (Data(response.body.utf8), Self.response(request, status: response.status, headers: response.headers))
    }

    private static func response(_ request: URLRequest, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
    }
}

final class TestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(_ seconds: Double) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

actor SleepLog {
    private(set) var calls: [Double] = []
    func record(_ seconds: Double) { calls.append(seconds) }
}

let testConfiguration = GitHubConfiguration(clientID: "Iv23liTEST", appSlug: "relvora")

func tokens(expiresIn seconds: Double, now: Date, refreshable: Bool = true, access: String = "ghu_OLD") -> TokenSet {
    TokenSet(
        accessToken: Secret(access),
        refreshToken: refreshable ? Secret("ghr_OLD") : nil,
        accessTokenExpiresAt: now.addingTimeInterval(seconds),
        refreshTokenExpiresAt: refreshable ? now.addingTimeInterval(86_400 * 30) : nil
    )
}

let refreshedTokenJSON = """
    {"access_token":"ghu_NEW","expires_in":28800,"refresh_token":"ghr_NEW","refresh_token_expires_in":15897600,"token_type":"bearer"}
    """

/// A signed-in API client over the mock, with a recorded sleeper and controllable clock.
struct Harness {
    let mock = MockGitHub()
    let clock = TestClock()
    let sleeps = SleepLog()
    let store: InMemoryCredentialStore
    let session: GitHubSession
    let api: GitHubAPIClient

    init(tokenLifetime: Double = 3600) {
        store = InMemoryCredentialStore(nil)
        let clock = clock
        let deviceFlow = DeviceFlowClient(
            configuration: testConfiguration, transport: mock, sleep: { _ in }, now: { clock.now })
        session = GitHubSession(store: store, deviceFlow: deviceFlow, now: { clock.now })
        let sleeps = sleeps
        api = GitHubAPIClient(
            configuration: testConfiguration, session: session, transport: mock,
            sleep: { await sleeps.record($0) })
        store.save(tokens(expiresIn: tokenLifetime, now: clock.now))
    }
}

// MARK: - Sample payloads

enum Payload {
    static let repository = """
        {"id": 42, "name": "app", "owner": {"login": "octo"}, "private": true, "default_branch": "main",
         "html_url": "https://github.com/octo/app", "description": "The app"}
        """

    static let releases = """
        [
          {"id": 8, "tag_name": "v1.1.0-beta.1", "name": "", "draft": true, "prerelease": true,
           "created_at": "2026-02-01T00:00:00Z", "published_at": null, "target_commitish": "main",
           "html_url": "https://github.com/octo/app/releases/tag/untagged-1", "body": null},
          {"id": 7, "tag_name": "v1.0.0", "name": "One", "draft": false, "prerelease": false,
           "created_at": "2026-01-01T00:00:00Z", "published_at": "2026-01-02T00:00:00Z",
           "target_commitish": "main", "html_url": "https://github.com/octo/app/releases/tag/v1.0.0", "body": "Notes"},
          {"id": 6, "tag_name": "v0.9.0", "name": "Beta", "draft": false, "prerelease": true,
           "created_at": "2025-12-01T00:00:00Z", "published_at": "2025-12-02T00:00:00Z",
           "target_commitish": "main", "html_url": "https://github.com/octo/app/releases/tag/v0.9.0", "body": null}
        ]
        """

    static let tags = """
        [{"name": "v1.0.0", "commit": {"sha": "aaa111"}}, {"name": "v0.9.0", "commit": {"sha": "bbb222"}}]
        """

    static func commit(_ sha: String, _ message: String, login: String? = "ann", day: Int = 3) -> String {
        let author = login.map { #"{"login": "\#($0)"}"# } ?? "null"
        return """
            {"sha": "\(sha)", "html_url": "https://github.com/octo/app/commit/\(sha)",
             "commit": {"message": \(String(reflecting: message)), "author": {"name": "Ann", "date": "2026-01-\(String(format: "%02d", day))T00:00:00Z"}},
             "author": \(author)}
            """
    }

    static func compare(_ commits: [String], total: Int? = nil) -> String {
        """
        {"total_commits": \(total ?? commits.count), "html_url": "https://github.com/octo/app/compare/v1.0.0...main",
         "commits": [\(commits.joined(separator: ","))]}
        """
    }

    static func release(_ id: Int, tag: String, draft: Bool, target: String = "main") -> String {
        """
        {"id": \(id), "tag_name": "\(tag)", "name": "\(tag)", "draft": \(draft), "prerelease": false,
         "created_at": "2026-02-01T00:00:00Z", "published_at": \(draft ? "null" : "\"2026-02-02T00:00:00Z\""),
         "target_commitish": "\(target)", "html_url": "https://github.com/octo/app/releases/tag/\(draft ? "untagged-\(id)" : tag)",
         "body": "Notes"}
        """
    }

    static func pull(_ number: Int, title: String, merged: Bool = true, base: String = "main") -> String {
        """
        {"number": \(number), "title": "\(title)", "html_url": "https://github.com/octo/app/pull/\(number)",
         "merged_at": \(merged ? "\"2026-01-04T00:00:00Z\"" : "null"), "user": {"login": "bob"},
         "labels": [{"name": "bug"}], "base": {"ref": "\(base)"}}
        """
    }
}
