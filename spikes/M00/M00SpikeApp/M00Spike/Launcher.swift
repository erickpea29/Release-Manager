import CredentialSpike
import Foundation
import PersistenceSpike

/// Headless verification modes run from Terminal against the real, sandboxed app bundle:
///   M00Spike.app/Contents/MacOS/M00Spike --env | --seed <name> | --dump | --keychain | --keychain-write | --keychain-read
@main
struct Launcher {
    static func main() {
        if let check = HeadlessCheck(arguments: CommandLine.arguments) {
            Task { exit(await check.run()) }
            dispatchMain()
        }
        M00SpikeApp.main()
    }
}

enum AppStore {
    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "M00Spike", directoryHint: .isDirectory).appending(path: "spike.store")
    }

    static func makeRepository() throws -> SwiftDataProjectRepository {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return SwiftDataProjectRepository(modelContainer: try SpikeStore.makeContainer(url: url))
    }
}

struct HeadlessCheck {
    private let arguments: [String]
    private static let keychainService = "com.erickpea29.ReleaseManager.M00Spike"
    private static let modes: Set = ["--env", "--seed", "--dump", "--keychain", "--keychain-write", "--keychain-read"]

    init?(arguments: [String]) {
        guard let mode = arguments.dropFirst().first, Self.modes.contains(mode) else { return nil }
        self.arguments = Array(arguments.dropFirst())
    }

    func run() async -> Int32 {
        do {
            switch arguments[0] {
            case "--env":
                let sandboxID = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
                print("sandboxed=\(sandboxID != nil) container=\(sandboxID ?? "-")")
                print("store=\(AppStore.url.path)")
            case "--seed":
                let name = arguments.count > 1 ? arguments[1] : "Seeded \(Date.now.formatted(.iso8601))"
                try await AppStore.makeRepository().save(ProjectSummary(name: name))
                print("seeded '\(name)'")
            case "--dump":
                let projects = try await AppStore.makeRepository().allProjects()
                print("projects=\(projects.count)")
                for project in projects { print("- \(project.name) [\(project.slug)] \(project.id)") }
            case "--keychain":
                for flavor in KeychainFlavor.allCases {
                    print("keychain[\(flavor.rawValue)] round-trip: \(KeychainProbe.roundTrip(service: Self.keychainService, flavor: flavor))")
                }
            case "--keychain-write":
                // Persists across rebuilds so a later build can test whether re-signing triggers ACL prompts.
                let store = KeychainCredentialStore(service: Self.keychainService, flavor: flavor())
                try store.write(Data("m00-persisted-probe".utf8), account: "persisted-probe")
                print("keychain[\(store.flavor.rawValue)] persisted probe written")
            case "--keychain-read":
                let store = KeychainCredentialStore(service: Self.keychainService, flavor: flavor())
                let value = try store.read(account: "persisted-probe", allowUserInteraction: false)
                print("keychain[\(store.flavor.rawValue)] persisted probe: \(value.map { _ in "readable without prompt" } ?? "not found")")
                try store.delete(account: "persisted-probe")
            default:
                return 64
            }
            return 0
        } catch {
            print("FAILED: \(error)")
            return 1
        }
    }

    private func flavor() -> KeychainFlavor {
        arguments.contains("dataProtection") ? .dataProtection : .fileBased
    }
}
