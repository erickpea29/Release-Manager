import Foundation

public struct DeviceCode: Sendable, Equatable, Decodable {
    public let deviceCode: Secret
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = Secret(try container.decode(String.self, forKey: .deviceCode))
        userCode = try container.decode(String.self, forKey: .userCode)
        verificationURI = try container.decode(URL.self, forKey: .verificationURI)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        interval = try container.decode(Int.self, forKey: .interval)
    }
}

public struct UserAccessToken: Sendable, Equatable {
    public let accessToken: Secret
    /// `nil` when the GitHub App has user-token expiration turned off.
    public let expiresIn: Int?
    public let refreshToken: Secret?
    public let refreshTokenExpiresIn: Int?
    public let tokenType: String
}

public enum DeviceFlowError: Error, Equatable {
    case expiredToken
    case accessDenied
    case deviceFlowDisabled
    case incorrectClientCredentials
    case badRefreshToken
    case oauth(code: String, description: String?)
    case unexpectedResponse(status: Int)
}

/// OAuth 2.0 device authorization grant against github.com. Uses only the public client ID.
public struct DeviceFlowClient: Sendable {
    public typealias Sleeper = @Sendable (_ seconds: Int) async throws -> Void

    private let clientID: String
    private let transport: any HTTPTransport
    private let sleep: Sleeper
    private let baseURL = URL(string: "https://github.com")!

    public init(
        clientID: String,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.clientID = clientID
        self.transport = transport
        self.sleep = sleep
    }

    public func requestDeviceCode() async throws -> DeviceCode {
        let (data, response) = try await post("login/device/code", [("client_id", clientID)])
        if let error = try? JSONDecoder().decode(TokenEndpointBody.self, from: data), let code = error.error {
            throw Self.map(code: code, description: error.errorDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DeviceFlowError.unexpectedResponse(status: response.statusCode)
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Polls until the user approves, denies, or the device code expires. Honors `slow_down`.
    public func pollForAccessToken(_ code: DeviceCode) async throws -> UserAccessToken {
        var interval = max(code.interval, 1)
        var elapsed = 0
        while elapsed < code.expiresIn {
            try await sleep(interval)
            elapsed += interval
            try Task.checkCancellation()

            let body = try await tokenRequest([
                ("client_id", clientID),
                ("device_code", code.deviceCode.rawValue),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            switch body.error {
            case nil:
                return try body.token()
            case "authorization_pending":
                continue
            case "slow_down":
                interval = body.interval ?? interval + 5
            default:
                throw Self.map(code: body.error!, description: body.errorDescription)
            }
        }
        throw DeviceFlowError.expiredToken
    }

    /// Spike: GitHub documents `client_secret` as required here. Called without it to verify empirically.
    public func refreshWithoutClientSecret(_ refreshToken: Secret) async throws -> UserAccessToken {
        let body = try await tokenRequest([
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken.rawValue),
        ])
        if let code = body.error { throw Self.map(code: code, description: body.errorDescription) }
        return try body.token()
    }

    private func tokenRequest(_ parameters: [(String, String)]) async throws -> TokenEndpointBody {
        let (data, response) = try await post("login/oauth/access_token", parameters)
        guard let body = try? JSONDecoder().decode(TokenEndpointBody.self, from: data) else {
            throw DeviceFlowError.unexpectedResponse(status: response.statusCode)
        }
        return body
    }

    private func post(_ path: String, _ parameters: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.encode(parameters)
        return try await transport.send(request)
    }

    static func map(code: String, description: String?) -> DeviceFlowError {
        switch code {
        // GitHub's docs name the same condition three ways.
        case "expired_token", "token_expired", "bad_verification_code": .expiredToken
        case "access_denied": .accessDenied
        case "device_flow_disabled": .deviceFlowDisabled
        case "incorrect_client_credentials": .incorrectClientCredentials
        case "bad_refresh_token": .badRefreshToken
        default: .oauth(code: code, description: description)
        }
    }
}

/// The token endpoint returns HTTP 200 for both success and OAuth errors, distinguished by fields.
struct TokenEndpointBody: Decodable {
    let accessToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let error: String?
    let errorDescription: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
        case errorDescription = "error_description"
        case interval
    }

    func token() throws -> UserAccessToken {
        guard let accessToken else { throw DeviceFlowError.oauth(code: "missing_access_token", description: nil) }
        return UserAccessToken(
            accessToken: Secret(accessToken),
            expiresIn: expiresIn,
            refreshToken: refreshToken.map(Secret.init),
            refreshTokenExpiresIn: refreshTokenExpiresIn,
            tokenType: tokenType ?? "bearer"
        )
    }
}
