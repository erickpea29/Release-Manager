import Foundation
import GitHubIntegration
import Observation
import RelvoraCore

/// The GitHub services this build uses, created from the app's public configuration.
struct GitHubServices: Sendable {
    let configuration: GitHubConfiguration
    let session: GitHubSession
    let deviceFlow: DeviceFlowClient
    let api: GitHubAPIClient
    let sync: GitHubSyncService
    let cache: SnapshotCache

    /// `nil` when the build has no client ID configured.
    static func live(bundle: Bundle = .main) -> GitHubServices? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "RelvoraGitHubClientID") as? String,
            !clientID.isEmpty, !clientID.hasPrefix("$(")
        else { return nil }
        let slug = (bundle.object(forInfoDictionaryKey: "RelvoraGitHubAppSlug") as? String).flatMap {
            $0.isEmpty || $0.hasPrefix("$(") ? nil : $0
        }
        let configuration = GitHubConfiguration(clientID: clientID, appSlug: slug)
        let transport = URLSessionTransport()
        let deviceFlow = DeviceFlowClient(configuration: configuration, transport: transport)
        let session = GitHubSession(store: KeychainCredentialStore(), deviceFlow: deviceFlow)
        let api = GitHubAPIClient(configuration: configuration, session: session, transport: transport)
        return GitHubServices(
            configuration: configuration, session: session, deviceFlow: deviceFlow, api: api,
            sync: GitHubSyncService(api: api), cache: SnapshotCache(directory: SnapshotCache.defaultDirectory))
    }
}

/// GitHub account state and repository data shared by all views.
@Observable
final class GitHubModel {
    enum Status: Equatable {
        /// This build has no GitHub App configured.
        case unavailable
        case checking
        case disconnected
        case connected(GitHubAccount)
        case needsReauthorization
    }

    enum ConnectStep: Equatable {
        case requestingCode
        case waiting(userCode: String, url: URL, expiresAt: Date)
        case failed(String)
    }

    enum SyncState: Equatable {
        case idle
        case refreshing
        case failed(String)
    }

    private(set) var status: Status
    private(set) var connectStep: ConnectStep?
    private(set) var snapshots: [Int64: RepositorySnapshot] = [:]
    private(set) var syncStates: [Int64: SyncState] = [:]
    let services: GitHubServices?
    private var connectTask: Task<Void, Never>?

    init(services: GitHubServices?) {
        self.services = services
        self.status = services == nil ? .unavailable : .checking
    }

    var configuration: GitHubConfiguration? { services?.configuration }

    var account: GitHubAccount? {
        if case .connected(let account) = status { account } else { nil }
    }

    var isConnected: Bool { account != nil }

    /// Reads the stored sign-in. Works offline: the account is saved with the tokens.
    func loadStatus() async {
        guard let services else { return }
        do {
            guard var tokens = try await services.session.tokens() else {
                status = .disconnected
                return
            }
            if let account = tokens.account {
                status = .connected(account)
            } else {
                let account = try await services.api.currentUser()
                tokens.account = account
                try await services.session.signIn(tokens)
                status = .connected(account)
            }
        } catch .reauthorizationRequired {
            status = .needsReauthorization
        } catch {
            status = .disconnected
        }
    }

    // MARK: Connecting (device flow)

    func startConnecting() {
        guard let services, connectTask == nil else { return }
        connectStep = .requestingCode
        connectTask = Task {
            defer { connectTask = nil }
            do {
                let code = try await services.deviceFlow.requestDeviceCode()
                connectStep = .waiting(userCode: code.userCode, url: code.verificationURL, expiresAt: code.expiresAt)
                var tokens = try await services.deviceFlow.waitForAuthorization(code)
                try await services.session.signIn(tokens)
                let account = try await services.api.currentUser()
                tokens.account = account
                try await services.session.signIn(tokens)
                status = .connected(account)
                connectStep = nil
            } catch {
                connectStep = Task.isCancelled ? nil : .failed(AppAlert.message(for: error))
            }
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        connectStep = nil
    }

    /// Forgets the sign-in on this Mac. Cached repository data stays.
    func disconnect() async {
        cancelConnecting()
        try? await services?.session.signOut()
        status = .disconnected
    }

    // MARK: Repositories

    func installationRepositories() async throws -> [GitHubRepository] {
        guard let services else { throw GitHubError.notConnected }
        do {
            return try await services.api.installationRepositories()
        } catch {
            noteAuthorizationProblem(error)
            throw error
        }
    }

    /// The last successful snapshot, from memory or the on-disk cache.
    func snapshot(for repositoryID: Int64) -> RepositorySnapshot? {
        if let snapshot = snapshots[repositoryID] { return snapshot }
        guard let cached = services?.cache.load(repositoryID: repositoryID) else { return nil }
        snapshots[repositoryID] = cached
        return cached
    }

    func syncState(for repositoryID: Int64) -> SyncState { syncStates[repositoryID] ?? .idle }

    /// Fetches fresh data. On failure the cached snapshot stays untouched and the error is kept for display.
    /// Returns the repository's current metadata on success, so the connection can record renames.
    func refresh(repositoryID: Int64) async -> GitHubRepository? {
        guard let services, syncState(for: repositoryID) != .refreshing else { return nil }
        syncStates[repositoryID] = .refreshing
        do {
            let snapshot = try await services.sync.snapshot(repositoryID: repositoryID)
            try? services.cache.save(snapshot)
            snapshots[repositoryID] = snapshot
            syncStates[repositoryID] = .idle
            return snapshot.repository
        } catch {
            noteAuthorizationProblem(error)
            syncStates[repositoryID] = .failed(AppAlert.message(for: error))
            return nil
        }
    }

    private func noteAuthorizationProblem(_ error: GitHubError) {
        switch error {
        case .reauthorizationRequired: status = .needsReauthorization
        case .notConnected: status = .disconnected
        default: break
        }
    }
}
