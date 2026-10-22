import Foundation
import Testing

@testable import GitHubIntegration

@Suite("Device flow")
struct DeviceFlowTests {
    private let deviceCodeJSON = """
        {"device_code":"dc-123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """

    @Test("Requests a code with the client ID only")
    func requestCode() async throws {
        let mock = MockGitHub()
        await mock.on("/login/device/code", json: deviceCodeJSON)
        let clock = TestClock()
        let client = DeviceFlowClient(
            configuration: testConfiguration, transport: mock, sleep: { _ in }, now: { clock.now })

        let code = try await client.requestDeviceCode()

        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.expiresAt == clock.now.addingTimeInterval(900))
        let body = String(decoding: await mock.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "client_id=Iv23liTEST")
    }

    @Test("Waits through pending and slow_down, then returns expiring tokens")
    func approval() async throws {
        let mock = MockGitHub()
        await mock.on("/login/device/code", json: deviceCodeJSON)
        await mock.on(
            "/login/oauth/access_token",
            .init(body: #"{"error":"authorization_pending"}"#),
            .init(body: #"{"error":"slow_down","interval":10}"#),
            .init(body: refreshedTokenJSON))
        let clock = TestClock()
        let sleeps = SleepLog()
        let client = DeviceFlowClient(
            configuration: testConfiguration, transport: mock,
            sleep: { seconds in await sleeps.record(Double(seconds)) }, now: { clock.now })

        let tokens = try await client.waitForAuthorization(try await client.requestDeviceCode())

        #expect(await sleeps.calls == [5, 5, 10])
        #expect(tokens.accessToken.rawValue == "ghu_NEW")
        #expect(tokens.accessTokenExpiresAt == clock.now.addingTimeInterval(28_800))
        #expect(tokens.refreshTokenExpiresAt == clock.now.addingTimeInterval(15_897_600))
    }

    @Test(
        "Declined, disabled, and expired codes map to specific errors",
        arguments: [
            (#"{"error":"access_denied"}"#, GitHubError.authorizationDenied),
            (#"{"error":"device_flow_disabled"}"#, .deviceFlowDisabled),
            (#"{"error":"expired_token"}"#, .authorizationExpired),
        ])
    func failures(body: String, expected: GitHubError) async throws {
        let mock = MockGitHub()
        await mock.on("/login/device/code", json: deviceCodeJSON)
        await mock.on("/login/oauth/access_token", json: body)
        let client = DeviceFlowClient(configuration: testConfiguration, transport: mock, sleep: { _ in })
        let code = try await client.requestDeviceCode()
        await #expect(throws: expected) { try await client.waitForAuthorization(code) }
    }

    @Test("Stops when the code's lifetime runs out")
    func lifetime() async throws {
        let mock = MockGitHub()
        await mock.on("/login/device/code", json: deviceCodeJSON)
        await mock.on("/login/oauth/access_token", json: #"{"error":"authorization_pending"}"#)
        let clock = TestClock()
        let client = DeviceFlowClient(
            configuration: testConfiguration, transport: mock, sleep: { clock.advance(Double($0)) }, now: { clock.now })
        let code = try await client.requestDeviceCode()
        await #expect(throws: GitHubError.authorizationExpired) { try await client.waitForAuthorization(code) }
        #expect(await mock.requests(to: "/login/oauth/access_token").count == 180)
    }
}

@Suite("Session tokens")
struct SessionTests {
    @Test("A valid token is used without any network request")
    func validToken() async throws {
        let harness = Harness(tokenLifetime: 3600)
        #expect(try await harness.session.accessToken().rawValue == "ghu_OLD")
        #expect(await harness.mock.requests.isEmpty)
    }

    @Test("A token about to expire is refreshed without a client secret, and the rotation is saved")
    func refresh() async throws {
        let harness = Harness(tokenLifetime: 120)
        var stored = harness.store.load()!
        stored.account = .init(id: 1, login: "erick", name: nil, htmlURL: URL(string: "https://github.com/erick")!)
        harness.store.save(stored)
        await harness.mock.on("/login/oauth/access_token", json: refreshedTokenJSON)

        #expect(try await harness.session.accessToken().rawValue == "ghu_NEW")

        let body = String(decoding: await harness.mock.requests.first?.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=ghr_OLD"))
        #expect(!body.contains("secret"))
        #expect(harness.store.load()?.refreshToken?.rawValue == "ghr_NEW")
        #expect(harness.store.load()?.account?.login == "erick")
    }

    @Test("Concurrent requests share one refresh")
    func coalescing() async throws {
        let harness = Harness(tokenLifetime: 60)
        await harness.mock.on("/login/oauth/access_token", .init(body: refreshedTokenJSON, delay: .milliseconds(100)))

        async let first = harness.session.accessToken()
        async let second = harness.session.accessToken()
        async let third = harness.session.accessToken()
        let tokens = try await [first, second, third]

        #expect(tokens.allSatisfy { $0.rawValue == "ghu_NEW" })
        #expect(await harness.mock.requests(to: "/login/oauth/access_token").count == 1)
    }

    @Test("A rejected refresh token signs the user out")
    func badRefreshToken() async throws {
        let harness = Harness(tokenLifetime: 60)
        await harness.mock.on("/login/oauth/access_token", json: #"{"error":"bad_refresh_token"}"#)
        await #expect(throws: GitHubError.reauthorizationRequired) { try await harness.session.accessToken() }
        #expect(harness.store.load() == nil)
    }

    @Test("Expired refresh token or no sign-in needs no network to fail")
    func noNetworkFailures() async throws {
        let harness = Harness()
        var expired = tokens(expiresIn: -10, now: harness.clock.now)
        expired.refreshTokenExpiresAt = harness.clock.now.addingTimeInterval(-1)
        harness.store.save(expired)
        await #expect(throws: GitHubError.reauthorizationRequired) { try await harness.session.accessToken() }

        await #expect(throws: GitHubError.notConnected) { try await harness.session.accessToken() }
        #expect(await harness.mock.requests.isEmpty)
    }

    @Test("Tokens never appear in descriptions")
    func redaction() {
        let set = tokens(expiresIn: 60, now: .now, access: "ghu_SUPERSECRET")
        var dumped = ""
        dump(set, to: &dumped)
        for text in ["\(set)", String(reflecting: set), dumped] {
            #expect(!text.contains("SUPERSECRET") && !text.contains("ghr_OLD"))
        }
    }
}
