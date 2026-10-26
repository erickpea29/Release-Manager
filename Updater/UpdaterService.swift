import Foundation
import RelvoraCore
import RelvoraUpdates

final class UpdaterListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only Relvora can reach this service; when it's signed, the client must also be signed by the same team.
        if let team = CodeSignature.ownTeamIdentifier(), SigningPolicy.isTeamID(team) {
            connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        connection.exportedInterface = UpdaterXPC.interface()
        connection.exportedObject = UpdaterService()
        connection.resume()
        return true
    }
}

final class UpdaterService: NSObject, UpdaterXPCProtocol {
    /// One install at a time, across connections.
    private static let installing = NSLock()

    /// Release builds accept only Developer ID, notarized updates; Debug builds (local checks) any certificate of the
    /// same team.
    private static var policy: SigningPolicy {
        #if DEBUG
            .development
        #else
            .developerID
        #endif
    }

    func installUpdate(
        _ archive: FileHandle, version: String, sha256: String,
        withReply reply: @escaping @Sendable (NSError?) -> Void
    ) {
        guard Self.installing.try() else {
            reply(UpdateInstallError.busy.xpcError)
            return
        }
        defer { Self.installing.unlock() }
        do throws(UpdateInstallError) {
            guard let version = SemanticVersion(version) else { throw .wrongVersion(found: version) }
            try UpdateInstaller.forHostApp(policy: Self.policy).install(
                archive: archive, version: version, sha256: sha256)
            reply(nil)
        } catch {
            reply(error.xpcError)
        }
    }
}
