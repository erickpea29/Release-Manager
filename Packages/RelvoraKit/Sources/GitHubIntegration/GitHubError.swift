import Foundation

/// Every GitHub failure the app can see, with a message and a concrete next step for the user.
public enum GitHubError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case reauthorizationRequired
    case authorizationExpired
    case authorizationDenied
    case deviceFlowDisabled
    case offline
    case timedOut
    case rateLimited(resetAt: Date?)
    case forbidden(neededPermission: String?)
    case notFound
    case validationFailed(message: String?)
    case conflict
    case server(status: Int)
    case credentialStorage(status: Int32)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "GitHub isn’t connected."
        case .reauthorizationRequired: "Your GitHub sign-in expired or was revoked."
        case .authorizationExpired: "The sign-in code expired before it was approved."
        case .authorizationDenied: "GitHub access was declined."
        case .deviceFlowDisabled: "Device sign-in is turned off for the Relvora GitHub App."
        case .offline: "You’re offline."
        case .timedOut: "GitHub didn’t respond in time."
        case .rateLimited: "GitHub’s request limit was reached."
        case .forbidden: "Relvora doesn’t have permission to do that on GitHub."
        case .notFound: "GitHub couldn’t find this repository, or Relvora can’t access it."
        case .validationFailed(let message): "GitHub rejected the request\(message.map { ": \($0)" } ?? ".")"
        case .conflict: "GitHub reported a conflict."
        case .server(let status): "GitHub is having problems (error \(status))."
        case .credentialStorage: "Relvora couldn’t access your GitHub sign-in in the Keychain."
        case .invalidResponse: "GitHub sent an unexpected response."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notConnected:
            "Connect your GitHub account in Settings › GitHub."
        case .reauthorizationRequired:
            "Connect GitHub again in Settings › GitHub. Cached data is still available."
        case .authorizationExpired:
            "Start connecting again and enter the new code within 15 minutes."
        case .authorizationDenied:
            "Start again and choose Authorize on GitHub."
        case .deviceFlowDisabled:
            "Turn on “Enable Device Flow” in the Relvora app’s settings on GitHub."
        case .offline:
            "Cached data is shown. Refresh when you’re back online."
        case .timedOut:
            "Try again in a moment. Cached data is still shown."
        case .rateLimited(let resetAt):
            resetAt.map {
                "Try again after \($0.formatted(date: .omitted, time: .shortened)). Cached data is still shown."
            }
                ?? "Wait a minute and try again. Cached data is still shown."
        case .forbidden(let permission):
            "The Relvora GitHub App needs \(permission ?? "more") access. Update its permissions on GitHub, then accept them for your installation."
        case .notFound:
            "Make sure the Relvora app is installed on this repository: GitHub › Settings › Applications › Relvora › Configure."
        case .validationFailed:
            "Check the values and try again."
        case .conflict:
            "Refresh and try again."
        case .server:
            "Try again later. Cached data is still shown."
        case .credentialStorage:
            "Disconnect and connect GitHub again in Settings › GitHub."
        case .invalidResponse:
            "Try again. If this keeps happening, report it."
        }
    }

    /// Classifies an HTTP response. Returns `nil` for success.
    static func classify(_ response: HTTPURLResponse, body: Data) -> GitHubError? {
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
        let remaining = header("x-ratelimit-remaining").flatMap(Int.init)
        let reset = header("x-ratelimit-reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        let retryAfter = header("retry-after").flatMap(TimeInterval.init)
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message

        switch response.statusCode {
        case 200..<300, 304:
            return nil
        case 401:
            return .reauthorizationRequired
        case 403, 429:
            if response.statusCode == 429 || remaining == 0 || retryAfter != nil
                || message?.localizedCaseInsensitiveContains("rate limit") == true
            {
                return .rateLimited(resetAt: retryAfter.map { Date.now.addingTimeInterval($0) } ?? reset)
            }
            return .forbidden(neededPermission: header("x-accepted-github-permissions"))
        case 404:
            return .notFound
        case 409:
            return .conflict
        case 422:
            return .validationFailed(message: message)
        case 500..<600:
            return .server(status: response.statusCode)
        default:
            return .invalidResponse("HTTP \(response.statusCode)")
        }
    }

    static func from(_ error: URLError) -> GitHubError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            .offline
        case .timedOut:
            .timedOut
        default:
            .invalidResponse(error.code.rawValue.description)
        }
    }

    /// Worth retrying automatically (idempotent requests only).
    var isTransient: Bool {
        switch self {
        case .timedOut: true
        case .server(let status): [500, 502, 503, 504].contains(status)
        default: false
        }
    }

    private struct ErrorBody: Decodable {
        let message: String?
    }
}
