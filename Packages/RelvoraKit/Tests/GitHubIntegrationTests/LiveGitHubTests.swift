import Foundation
import Testing

@testable import GitHubIntegration

/// Opt-in checks against real GitHub. Skipped unless both variables are set; never run in CI.
///
///     RELVORA_LIVE_GITHUB_TOKEN=ghu_… RELVORA_LIVE_GITHUB_REPOSITORY_ID=1429211413 swift test --filter LiveGitHub
///
/// The token is only held in memory and never printed.
@Suite("Live GitHub (opt-in)")
struct LiveGitHubTests {
    private static let token = ProcessInfo.processInfo.environment["RELVORA_LIVE_GITHUB_TOKEN"]
    private static let repositoryID = ProcessInfo.processInfo.environment["RELVORA_LIVE_GITHUB_REPOSITORY_ID"]
        .flatMap(Int64.init)

    @Test(.enabled(if: token != nil && repositoryID != nil))
    func snapshotOfRealRepository() async throws {
        let configuration = GitHubConfiguration(clientID: "unused-for-reads", appSlug: nil)
        let store = InMemoryCredentialStore(
            TokenSet(
                accessToken: Secret(Self.token!), refreshToken: nil, accessTokenExpiresAt: nil,
                refreshTokenExpiresAt: nil))
        let session = GitHubSession(store: store, deviceFlow: DeviceFlowClient(configuration: configuration))
        let api = GitHubAPIClient(configuration: configuration, session: session)

        let user = try await api.currentUser()
        #expect(!user.login.isEmpty)
        let snapshot = try await GitHubSyncService(api: api).snapshot(repositoryID: Self.repositoryID!)
        #expect(snapshot.repository.id == Self.repositoryID)
        #expect(snapshot.unreleased != nil || snapshot.repository.defaultBranch == nil)
    }
}
