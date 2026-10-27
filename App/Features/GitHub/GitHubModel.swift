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
    let releases: GitHubReleaseRemote
    /// Relvora's own repository (`owner/name`), whose releases are its updates; `nil` when the build names none.
    let updateRepository: String?

    init(
        configuration: GitHubConfiguration, transport: any HTTPTransport, credentials: any CredentialStore,
        cache: SnapshotCache, updateRepository: String?
    ) {
        self.configuration = configuration
        self.updateRepository = updateRepository
        deviceFlow = DeviceFlowClient(configuration: configuration, transport: transport)
        session = GitHubSession(store: credentials, deviceFlow: deviceFlow)
        api = GitHubAPIClient(configuration: configuration, session: session, transport: transport)
        sync = GitHubSyncService(api: api)
        self.cache = cache
        releases = GitHubReleaseRemote(api: api)
    }

    /// `nil` when the build has no client ID configured.
    static func live(bundle: Bundle = .main) -> GitHubServices? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "RelvoraGitHubClientID") as? String,
            !clientID.isEmpty, !clientID.hasPrefix("$(")
        else { return nil }
        func setting(_ key: String) -> String? {
            let value = bundle.object(forInfoDictionaryKey: key) as? String
            return value.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        }
        return GitHubServices(
            configuration: GitHubConfiguration(clientID: clientID, appSlug: setting("RelvoraGitHubAppSlug")),
            transport: URLSessionTransport(), credentials: KeychainCredentialStore(),
            cache: SnapshotCache(directory: SnapshotCache.defaultDirectory),
            updateRepository: setting("RelvoraUpdateRepository"))
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
    /// Current repository metadata per GitHub ID, fetched once per launch for release preparation.
    private var repositories: [Int64: GitHubRepository] = [:]
    /// When each repository was last refreshed or tried, so automatic refreshes keep their interval after failures.
    private var lastAttempts: [Int64: Date] = [:]
    /// GitHub's rate limit is used up until then; automatic refreshes wait.
    private var rateLimitedUntil: Date?
    /// Changes between a base and a target commit, per repository; release preparation reads these repeatedly.
    private var changesCache: [String: (changes: UnreleasedChanges, notes: [String])] = [:]

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
        lastAttempts[repositoryID] = .now
        do {
            let snapshot = try await services.sync.snapshot(repositoryID: repositoryID)
            try? services.cache.save(snapshot)
            snapshots[repositoryID] = snapshot
            syncStates[repositoryID] = .idle
            return snapshot.repository
        } catch {
            noteAuthorizationProblem(error)
            if case .rateLimited(let resetAt) = error { rateLimitedUntil = resetAt ?? .now.addingTimeInterval(15 * 60) }
            syncStates[repositoryID] = .failed(AppAlert.message(for: error))
            return nil
        }
    }

    /// True when an automatic refresh should fetch this repository now (`RefreshSchedule`).
    func isRefreshDue(repositoryID: Int64, interval: TimeInterval) -> Bool {
        guard isConnected, syncState(for: repositoryID) != .refreshing else { return false }
        return RefreshSchedule.isDue(
            lastSynced: snapshot(for: repositoryID)?.fetchedAt, lastAttempt: lastAttempts[repositoryID],
            interval: interval, rateLimitedUntil: rateLimitedUntil, now: .now)
    }

    // MARK: Release preparation

    /// The repository as GitHub reports it now (renames and transfers included).
    func repository(id: Int64) async throws -> GitHubRepository {
        let services = try connectedServices()
        if let known = repositories[id] { return known }
        let repository = try await reading { try await services.api.repository(id: id) }
        repositories[id] = repository
        return repository
    }

    func branches(of repositoryID: Int64) async throws -> [RemoteBranch] {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.branches(of: repository).items }
    }

    /// The latest commits on `branch`, newest first.
    func commits(of repositoryID: Int64, branch: String) async throws -> [RemoteCommit] {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.commits(of: repository, branch: branch, limit: 30) }
    }

    /// Resolves a short SHA, branch, or tag to a commit with its full SHA.
    func commit(of repositoryID: Int64, ref: String) async throws -> RemoteCommit {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.commit(of: repository, ref: ref) }
    }

    /// Commits and merged pull requests from `base` to the target commit. Reuses the repository snapshot when the
    /// target is the default branch's head it was built from (ADR 0009: don't re-fetch what M03 already has).
    func changes(of repositoryID: Int64, base: String?, head: String, branch: String?) async throws
        -> (changes: UnreleasedChanges, notes: [String])
    {
        if let unreleased = snapshot(for: repositoryID)?.unreleased, unreleased.headSHA == head,
            unreleased.baseTag == base, unreleased.headRef == branch
        {
            return (unreleased, [])
        }
        let key = "\(repositoryID) \(base ?? "-") \(head)"
        if let cached = changesCache[key] { return cached }
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        let result = try await reading {
            try await services.sync.changes(in: repository, base: base, head: head, branch: branch)
        }
        changesCache[key] = result
        return result
    }

    // MARK: Pull requests and CI (ADR 0020)

    func openPullRequests(of repositoryID: Int64) async throws -> [PullRequest] {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.openPullRequests(of: repository) }
    }

    func closedPullRequests(of repositoryID: Int64) async throws -> [PullRequest] {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.closedPullRequests(of: repository) }
    }

    func pullRequest(of repositoryID: Int64, number: Int) async throws -> (
        pullRequest: PullRequest, mergeability: Mergeability
    ) {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.pullRequest(of: repository, number: number) }
    }

    func checkRuns(of repositoryID: Int64, sha: String) async throws -> [CheckRun] {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading { try await services.api.checkRuns(of: repository, sha: sha) }
    }

    /// The only GitHub write outside the release workflow: the user confirmed it in the merge sheet.
    func mergePullRequest(of repositoryID: Int64, number: Int, headSHA: String, method: MergeMethod) async throws
        -> String
    {
        let services = try connectedServices()
        let repository = try await repository(id: repositoryID)
        return try await reading {
            try await services.api.mergePullRequest(in: repository, number: number, headSHA: headSHA, method: method)
        }
    }

    private func connectedServices() throws(GitHubError) -> GitHubServices {
        guard let services else { throw .notConnected }
        return services
    }

    /// Notes sign-in problems from any GitHub read, so the connection status stays accurate.
    private func reading<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            noteError(error)
            throw error
        }
    }

    /// Workflow errors that come from GitHub update the connection status too.
    func noteError(_ error: any Error) {
        if let error = error as? GitHubError { noteAuthorizationProblem(error) }
    }

    private func noteAuthorizationProblem(_ error: GitHubError) {
        switch error {
        case .reauthorizationRequired: status = .needsReauthorization
        case .notConnected: status = .disconnected
        default: break
        }
    }
}
