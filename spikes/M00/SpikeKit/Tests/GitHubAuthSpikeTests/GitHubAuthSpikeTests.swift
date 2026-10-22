import Foundation
import Testing
@testable import GitHubAuthSpike

actor MockTransport: HTTPTransport {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw URLError(.resourceUnavailable) }
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        return (Data(stub.body.utf8), response)
    }
}

actor SleepRecorder {
    private(set) var calls: [Int] = []
    func record(_ seconds: Int) { calls.append(seconds) }
}

private func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> MockTransport.Stub {
    MockTransport.Stub(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
}

private let deviceCodeJSON = """
{"device_code":"dc-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
"""
private let tokenJSON = """
{"access_token":"ghu_abcdefSECRET","expires_in":28800,"refresh_token":"ghr_refreshSECRET","refresh_token_expires_in":15897600,"token_type":"bearer","scope":""}
"""

@Suite("Device flow")
struct DeviceFlowTests {
    @Test("Device code request sends only the public client ID")
    func deviceCodeRequest() async throws {
        let transport = MockTransport([json(deviceCodeJSON)])
        let client = DeviceFlowClient(clientID: "Iv23liTEST", transport: transport, sleep: { _ in })

        let code = try await client.requestDeviceCode()

        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.interval == 5)
        let request = try #require(await transport.requests.first)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(body == "client_id=Iv23liTEST")
        #expect(!body.contains("secret"))
    }

    @Test("Polling honors authorization_pending and slow_down before succeeding")
    func pollingSequence() async throws {
        let transport = MockTransport([
            json(#"{"error":"authorization_pending"}"#),
            json(#"{"error":"slow_down","interval":10}"#),
            json(tokenJSON),
        ])
        let sleeps = SleepRecorder()
        let client = DeviceFlowClient(clientID: "Iv23liTEST", transport: transport, sleep: { await sleeps.record($0) })
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(deviceCodeJSON.utf8))

        let token = try await client.pollForAccessToken(code)

        #expect(await sleeps.calls == [5, 5, 10])
        #expect(token.accessToken.kindPrefix == "ghu_")
        #expect(token.expiresIn == 28800)
        #expect(token.refreshToken != nil)
        let body = String(decoding: await transport.requests.last?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    @Test("A denied authorization surfaces as accessDenied")
    func accessDenied() async throws {
        let transport = MockTransport([json(#"{"error":"access_denied"}"#)])
        let client = DeviceFlowClient(clientID: "Iv23liTEST", transport: transport, sleep: { _ in })
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(deviceCodeJSON.utf8))

        await #expect(throws: DeviceFlowError.accessDenied) { try await client.pollForAccessToken(code) }
    }

    @Test("Polling stops once the device code lifetime is exhausted")
    func expiry() async throws {
        let shortLived = #"{"device_code":"dc","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","expires_in":10,"interval":5}"#
        let transport = MockTransport([json(#"{"error":"authorization_pending"}"#), json(#"{"error":"authorization_pending"}"#)])
        let client = DeviceFlowClient(clientID: "Iv23liTEST", transport: transport, sleep: { _ in })
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(shortLived.utf8))

        await #expect(throws: DeviceFlowError.expiredToken) { try await client.pollForAccessToken(code) }
        #expect(await transport.requests.count == 2)
    }

    @Test("A disabled device flow is reported distinctly")
    func deviceFlowDisabled() async throws {
        let transport = MockTransport([json(#"{"error":"device_flow_disabled"}"#, status: 400)])
        let client = DeviceFlowClient(clientID: "Iv23liTEST", transport: transport, sleep: { _ in })

        await #expect(throws: DeviceFlowError.deviceFlowDisabled) { try await client.requestDeviceCode() }
    }
}

@Suite("Secret handling")
struct SecretTests {
    @Test("Secrets are redacted in every textual representation")
    func redaction() throws {
        let token = UserAccessToken(
            accessToken: Secret("ghu_SUPERSECRET"),
            expiresIn: 1,
            refreshToken: Secret("ghr_SUPERSECRET"),
            refreshTokenExpiresIn: 1,
            tokenType: "bearer"
        )
        var dumped = ""
        dump(token, to: &dumped)
        let renderings = ["\(token)", String(describing: token), String(reflecting: token), dumped]
        for rendering in renderings {
            #expect(!rendering.contains("SUPERSECRET"), "leaked in: \(rendering)")
        }
    }
}

@Suite("REST probe")
struct RESTProbeTests {
    @Test("Requests carry bearer auth, the JSON media type, and a pinned API version")
    func headers() async throws {
        let transport = MockTransport([json("{}")])
        let probe = GitHubRESTProbe(token: Secret("ghu_x"), transport: transport)

        _ = try await probe.get("user")

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_x")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("Link header next-page extraction")
    func linkHeader() {
        let header = #"<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=5>; rel="last""#
        #expect(LinkHeader.next(in: header)?.absoluteString == "https://api.github.com/user/repos?page=2")
        #expect(LinkHeader.next(in: #"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(LinkHeader.next(in: nil) == nil)
    }

    @Test("Status codes map to typed errors", arguments: [
        (401, [:], GitHubAPIError.unauthorized),
        (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000"], .rateLimited(reset: Date(timeIntervalSince1970: 1_700_000_000), retryAfter: nil)),
        (403, ["retry-after": "60"], .rateLimited(reset: nil, retryAfter: 60)),
        (403, ["x-accepted-github-permissions": "contents=write"], .forbidden(acceptedPermissions: "contents=write")),
        (429, ["retry-after": "30"], .rateLimited(reset: nil, retryAfter: 30)),
        (404, [:], .notFound),
        (409, [:], .conflict),
        (422, [:], .validationFailed),
        (503, [:], .server(status: 503)),
    ] as [(Int, [String: String], GitHubAPIError)])
    func classification(status: Int, headers: [String: String], expected: GitHubAPIError) {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
        #expect(GitHubAPIError.classify(response) == expected)
    }
}
