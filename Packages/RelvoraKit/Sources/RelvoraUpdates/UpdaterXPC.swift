import Foundation
import RelvoraCore

/// The updater service inside Relvora (`Contents/XPCServices/RelvoraUpdater.xpc`). Only its app can connect to it.
@objc public protocol UpdaterXPCProtocol {
    /// Checks and installs the zip read from `archive` in place of the app that contains the service. Replies `nil`
    /// once the new version is in place, or an `UpdateInstallError.xpcError`.
    func installUpdate(
        _ archive: FileHandle, version: String, sha256: String,
        withReply reply: @escaping @Sendable (NSError?) -> Void)
}

public enum UpdaterXPC {
    /// The service's bundle ID: the app's, plus `.Updater`.
    public static func serviceName(appBundleID: String) -> String { appBundleID + ".Updater" }

    public static func interface() -> NSXPCInterface { NSXPCInterface(with: UpdaterXPCProtocol.self) }
}

/// The app's side of the updater connection. The archive is passed as an open file, so the service reads exactly the
/// file the app checked, without access to the app's container.
public struct UpdaterClient: Sendable {
    public let serviceName: String

    public init(appBundleID: String) {
        serviceName = UpdaterXPC.serviceName(appBundleID: appBundleID)
    }

    public func install(archive: URL, version: SemanticVersion, sha256: String) async throws(UpdateInstallError) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: archive)
        } catch {
            throw .unreadableArchive
        }
        defer { try? handle.close() }

        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = UpdaterXPC.interface()
        connection.resume()
        defer { connection.invalidate() }

        let reply: NSError? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(UpdateInstallError.updaterUnavailable(error.localizedDescription).xpcError)
            }
            guard let updater = proxy as? UpdaterXPCProtocol else {
                once.resume(UpdateInstallError.updaterUnavailable("no updater").xpcError)
                return
            }
            updater.installUpdate(handle, version: version.description, sha256: sha256) { once.resume($0) }
        }
        if let reply { throw UpdateInstallError(xpcError: reply) }
    }
}

/// The reply and the connection's error handler can both fire; the first one wins.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<NSError?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<NSError?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: NSError?) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

/// What the copy that installed an update tells the copy it opens: which process to wait for, what was installed, and
/// the backup saved first. Kept in the app's own settings for a minute, because macOS drops the launch arguments a
/// sandboxed app passes to an app it opens.
public struct RelaunchTicket: Codable, Sendable, Equatable {
    public var previousPID: Int32
    public var version: String
    public var backupPath: String?
    /// The previous copy's launch arguments: Debug builds keep their launch options across the relaunch.
    public var arguments: [String]
    public var createdAt: Date

    public static let key = "RelvoraRelaunchTicket"
    /// An older ticket is left over from a relaunch that never happened.
    public static let lifetime: TimeInterval = 60

    public init(previousPID: Int32, version: String, backupPath: String?, arguments: [String], createdAt: Date = .now) {
        self.previousPID = previousPID
        self.version = version
        self.backupPath = backupPath
        self.arguments = arguments
        self.createdAt = createdAt
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// The ticket left for this launch, if it's recent.
    public static func pending(in defaults: UserDefaults = .standard, now: Date = .now) -> RelaunchTicket? {
        guard let data = defaults.data(forKey: key),
            let ticket = try? JSONDecoder().decode(RelaunchTicket.self, from: data),
            now.timeIntervalSince(ticket.createdAt) < lifetime, now >= ticket.createdAt
        else { return nil }
        return ticket
    }

    public static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// The value after `-<name>` in the forwarded arguments.
    public func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: "-" + name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
