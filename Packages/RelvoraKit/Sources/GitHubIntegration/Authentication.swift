import Foundation
import RelvoraCore
import Security
import Synchronization

// MARK: - Tokens

/// A user's GitHub App tokens. Stored only in the Keychain; never logged (secrets print as `<redacted>`).
public struct TokenSet: Sendable, Equatable, Codable {
    public var accessToken: Secret
    public var refreshToken: Secret?
    /// `nil` when the GitHub App has token expiration turned off.
    public var accessTokenExpiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var account: GitHubAccount?

    public init(
        accessToken: Secret,
        refreshToken: Secret?,
        accessTokenExpiresAt: Date?,
        refreshTokenExpiresAt: Date?,
        account: GitHubAccount? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.account = account
    }

    /// Refresh five minutes early so a request never starts with a token about to expire.
    func needsRefresh(at date: Date) -> Bool {
        guard let expiresAt = accessTokenExpiresAt else { return false }
        return expiresAt.timeIntervalSince(date) < 300
    }

    func canRefresh(at date: Date) -> Bool {
        guard refreshToken != nil else { return false }
        return refreshTokenExpiresAt.map { $0 > date } ?? true
    }
}

// MARK: - Credential storage

public protocol CredentialStore: Sendable {
    func load() throws(GitHubError) -> TokenSet?
    func save(_ tokens: TokenSet) throws(GitHubError)
    func delete() throws(GitHubError)
}

/// One generic-password item holding the JSON-encoded token set, in the file-based keychain (ADR 0005).
public struct KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.erickpea29.Relvora.github", account: String = "user") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws(GitHubError) -> TokenSet? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let tokens = try? JSONDecoder().decode(TokenSet.self, from: data) else {
                // An unreadable item is useless; treat it as signed out rather than failing forever.
                try? delete()
                return nil
            }
            return tokens
        case errSecItemNotFound:
            return nil
        default:
            throw .credentialStorage(status: status)
        }
    }

    public func save(_ tokens: TokenSet) throws(GitHubError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw .invalidResponse("Token encoding failed")
        }
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .credentialStorage(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw .credentialStorage(status: status) }
    }

    public func delete() throws(GitHubError) {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .credentialStorage(status: status) }
    }
}

/// For tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private let tokens: Mutex<TokenSet?>

    public init(_ tokens: TokenSet? = nil) {
        self.tokens = Mutex(tokens)
    }

    public func load() -> TokenSet? { tokens.withLock { $0 } }
    public func save(_ tokens: TokenSet) { self.tokens.withLock { $0 = tokens } }
    public func delete() { tokens.withLock { $0 = nil } }
}

// MARK: - Device flow

public struct DeviceCode: Sendable, Equatable {
    public let deviceCode: Secret
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: Int
}

/// OAuth 2.0 device authorization grant against github.com, using only the public client ID.
/// Refreshing device-flow tokens needs no client secret (validated live in M00).
public struct DeviceFlowClient: Sendable {
    public typealias Sleeper = @Sendable (_ seconds: Int) async throws -> Void

    private let configuration: GitHubConfiguration
    private let transport: any HTTPTransport
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    public init(
        configuration: GitHubConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    public func requestDeviceCode() async throws(GitHubError) -> DeviceCode {
        let body = try await post("login/device/code", [("client_id", configuration.clientID)])
        if let error = body.error { throw Self.map(error) }
        guard let code = body.deviceCode, let userCode = body.userCode, let uri = body.verificationUri,
            let url = URL(string: uri), let expiresIn = body.expiresIn
        else { throw .invalidResponse("Incomplete device code response") }
        return DeviceCode(
            deviceCode: Secret(code), userCode: userCode, verificationURL: url,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)), interval: max(body.interval ?? 5, 1))
    }

    /// Polls until the user approves, declines, or the code expires. Honors `slow_down`. Cancellable.
    public func waitForAuthorization(_ code: DeviceCode) async throws(GitHubError) -> TokenSet {
        var interval = code.interval
        while now() < code.expiresAt {
            do {
                try await sleep(interval)
            } catch {
                throw .authorizationDenied  // cancelled by the user
            }
            let body = try await post(
                "login/oauth/access_token",
                [
                    ("client_id", configuration.clientID),
                    ("device_code", code.deviceCode.rawValue),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ])
            switch body.error {
            case nil: return try tokens(from: body)
            case "authorization_pending": continue
            case "slow_down": interval = body.interval ?? interval + 5
            case let error?: throw Self.map(error)
            }
        }
        throw .authorizationExpired
    }

    public func refresh(_ refreshToken: Secret) async throws(GitHubError) -> TokenSet {
        let body = try await post(
            "login/oauth/access_token",
            [
                ("client_id", configuration.clientID),
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken.rawValue),
            ])
        if let error = body.error { throw Self.map(error) }
        return try tokens(from: body)
    }

    private func tokens(from body: TokenEndpointBody) throws(GitHubError) -> TokenSet {
        guard let access = body.accessToken else { throw .invalidResponse("Missing access token") }
        let issued = now()
        return TokenSet(
            accessToken: Secret(access),
            refreshToken: body.refreshToken.map(Secret.init),
            accessTokenExpiresAt: body.expiresIn.map { issued.addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: body.refreshTokenExpiresIn.map { issued.addingTimeInterval(TimeInterval($0)) }
        )
    }

    /// GitHub's OAuth endpoints answer HTTP 200 for both success and errors; the body tells them apart.
    private func post(_ path: String, _ parameters: [(String, String)]) async throws(GitHubError) -> TokenEndpointBody {
        var request = URLRequest(url: configuration.webBaseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(parameters)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw GitHubError.from(error)
        } catch {
            throw .invalidResponse("Transport failure")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(TokenEndpointBody.self, from: data) else {
            throw GitHubError.classify(response, body: data) ?? .invalidResponse("Unreadable OAuth response")
        }
        return body
    }

    static func map(_ code: String) -> GitHubError {
        switch code {
        case "expired_token", "token_expired", "bad_verification_code", "incorrect_device_code": .authorizationExpired
        case "access_denied": .authorizationDenied
        case "device_flow_disabled": .deviceFlowDisabled
        case "bad_refresh_token": .reauthorizationRequired
        default: .invalidResponse("OAuth error \(code)")
        }
    }

    private struct TokenEndpointBody: Decodable {
        var deviceCode: String?
        var userCode: String?
        var verificationUri: String?
        var expiresIn: Int?
        var interval: Int?
        var accessToken: String?
        var refreshToken: String?
        var refreshTokenExpiresIn: Int?
        var error: String?
    }
}

// MARK: - Session

/// Owns the signed-in user's tokens. Refreshes before expiry and after a 401, one refresh at a time
/// (refresh tokens rotate, so parallel refreshes would invalidate each other).
public actor GitHubSession {
    private let store: any CredentialStore
    private let deviceFlow: DeviceFlowClient
    private let now: @Sendable () -> Date
    private var refreshing: Task<TokenSet, any Error>?

    public init(
        store: any CredentialStore, deviceFlow: DeviceFlowClient, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.deviceFlow = deviceFlow
        self.now = now
    }

    /// The stored sign-in, if any. Works offline.
    public func tokens() throws(GitHubError) -> TokenSet? { try store.load() }

    public func signIn(_ tokens: TokenSet) throws(GitHubError) { try store.save(tokens) }

    /// Forgets the tokens on this Mac. Revoking the authorization itself happens on github.com.
    public func signOut() throws(GitHubError) { try store.delete() }

    /// A usable access token, refreshed first if it is about to expire.
    public func accessToken() async throws(GitHubError) -> Secret {
        guard let tokens = try store.load() else { throw .notConnected }
        guard tokens.needsRefresh(at: now()) else { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    /// Called after a 401. Returns a new token, or throws `reauthorizationRequired` when only signing in again helps.
    public func tokenAfterUnauthorized(rejected: Secret) async throws(GitHubError) -> Secret {
        guard let tokens = try store.load() else { throw .notConnected }
        if tokens.accessToken != rejected { return tokens.accessToken }  // another request already refreshed
        return try await refresh(tokens).accessToken
    }

    private func refresh(_ tokens: TokenSet) async throws(GitHubError) -> TokenSet {
        if let refreshing {
            return try await Self.result(of: refreshing)
        }
        guard tokens.canRefresh(at: now()), let refreshToken = tokens.refreshToken else {
            try? store.delete()
            throw .reauthorizationRequired
        }
        let task = Task { [deviceFlow] in
            var fresh = try await deviceFlow.refresh(refreshToken)
            fresh.account = tokens.account
            return fresh
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await Self.result(of: task)
            try store.save(fresh)
            return fresh
        } catch .reauthorizationRequired {
            try? store.delete()
            throw .reauthorizationRequired
        }
    }

    private static func result(of task: Task<TokenSet, any Error>) async throws(GitHubError) -> TokenSet {
        do {
            return try await task.value
        } catch let error as GitHubError {
            throw error
        } catch {
            throw .invalidResponse("Refresh failed")
        }
    }
}
