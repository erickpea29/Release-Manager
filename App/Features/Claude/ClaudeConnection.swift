import Foundation
import Observation
import RelvoraCore
import RelvoraMCP

/// Claude's connection to Relvora: an MCP server on 127.0.0.1 while Relvora runs and Settings › Claude has it on
/// (ADR 0018). Claude Code connects with the setup command; it can read and change projects, versions, columns, and
/// tasks, but not delete projects or do anything on GitHub (ADR 0026).
@Observable
final class ClaudeConnection {
    enum Status: Equatable {
        case off
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    struct Activity: Equatable, Identifiable {
        let id = UUID()
        let date: Date
        let summary: String
    }

    static let defaultPort: UInt16 = 47823
    static let serverName = "relvora"
    /// How many of Claude's recent changes Settings › Claude lists.
    static let recentActivityLimit = 5

    private(set) var status: Status = .off
    /// What Claude did lately, newest first.
    private(set) var recentActivity: [Activity] = []
    /// `nil` until the connection is first turned on.
    private(set) var accessKey: String?

    @ObservationIgnored private let environment: AppEnvironment?
    @ObservationIgnored private let preferences: Preferences
    /// A fixed key from a launch option (UI tests), instead of the Keychain.
    @ObservationIgnored private let fixedKey: String?
    @ObservationIgnored private var server: LoopbackServer?
    /// Claude changed something: views showing the project reload, and the user may be notified.
    @ObservationIgnored var onChange: (RelvoraTools.Activity) async -> Void = { _ in }

    init(environment: AppEnvironment?, preferences: Preferences, fixedKey: String? = nil) {
        self.environment = environment
        self.preferences = preferences
        self.fixedKey = fixedKey
    }

    var port: UInt16 { UInt16(clamping: preferences.claudePort) }

    /// What to paste in Terminal once: every Claude Code session on this Mac can then use Relvora.
    var setupCommand: String? {
        accessKey.map { key in
            "claude mcp add --scope user --transport http \(Self.serverName) http://127.0.0.1:\(port)\(MCPEndpoint.path)"
                + " --header \"Authorization: Bearer \(key)\""
        }
    }

    /// Starts or stops the server to match Settings.
    func apply() {
        stop()
        guard preferences.claudeEnabled, let environment else { return }
        let key: String
        do {
            key = try fixedKey ?? accessKey ?? KeychainAccessKeyStore().loadOrCreate()
        } catch {
            status = .failed("Relvora couldn’t read its access key. \(AppAlert.message(for: error))")
            return
        }
        accessKey = key
        let tools = RelvoraTools(
            projects: environment.store.projects, groups: environment.store.groups, board: environment.board,
            plans: environment.releasePlans, checklist: environment.checklist,
            newProjectColumns: { @MainActor [preferences] in preferences.newProjectColumns }
        ) { [weak self] activity in
            await self?.record(activity)
        }
        let mcp = MCPServer(
            name: Self.serverName, title: "Relvora", version: AppModel.appVersion ?? "dev",
            instructions: RelvoraTools.instructions, tools: tools.all)
        let endpoint = MCPEndpoint(server: mcp, port: port, accessKey: key)
        let server = LoopbackServer(port: port) { request in await endpoint.respond(to: request) }
        self.server = server
        server.start { [weak self] state in
            Task { @MainActor in self?.update(state, of: server) }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .off
    }

    /// The current setup command stops working; Claude Code needs the new one.
    func replaceKey() {
        guard fixedKey == nil else { return }
        do {
            accessKey = try KeychainAccessKeyStore().replace()
            apply()
        } catch {
            status = .failed("Relvora couldn’t save a new access key. \(AppAlert.message(for: error))")
        }
    }

    private func update(_ state: LoopbackServer.State, of server: LoopbackServer) {
        guard server === self.server else { return }  // A server that was replaced since.
        switch state {
        case .starting: status = .starting
        case .ready(let port): status = .running(port: port)
        case .failed(let reason): status = .failed(reason)
        case .stopped: status = .off
        }
    }

    private func record(_ activity: RelvoraTools.Activity) async {
        recentActivity.insert(Activity(date: .now, summary: activity.summary), at: 0)
        recentActivity = Array(recentActivity.prefix(Self.recentActivityLimit))
        await onChange(activity)
    }
}
