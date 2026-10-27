import Foundation
import Security

/// Reads and writes the widget's snapshot in a folder: the App Group container in real use, a temporary folder in
/// tests and checks.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "WidgetSnapshot.json"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public var fileURL: URL { folder.appending(path: Self.fileName, directoryHint: .notDirectory) }

    /// `nil` when there's no snapshot yet, it can't be read, or it's in a format this build doesn't know.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return Self.decode(data)
    }

    /// Replaces the file in one step, so the widget never reads half of it.
    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// `nil` for anything but a snapshot in the current format.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        struct Header: Decodable { let format: Int }
        // The format is read first, so a snapshot from another version is never half understood.
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
            header.format == WidgetSnapshot.currentFormat
        else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: The shared container

extension WidgetSnapshotStore {
    /// The store in the App Group container the app and its widget share; `nil` when this copy can't use one.
    public static func shared() -> WidgetSnapshotStore? {
        sharedContainerURL().map(WidgetSnapshotStore.init(folder:))
    }

    /// The App Group container, when this process is entitled to a group prefixed with its signing team's ID (ADR
    /// 0024). macOS lets an app signed by that team use such a group without a provisioning profile, and without
    /// asking the user. An ad-hoc signed copy (CI, fresh clones, UI tests) has no team, so it never touches a group
    /// container: macOS would ask the user for consent.
    public static func sharedContainerURL() -> URL? {
        guard let group = usableGroup(teamID: OwnSignature.teamID(), groups: OwnSignature.appGroups()) else {
            return nil
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// The first of `groups` named "<teamID>.<something>".
    public static func usableGroup(teamID: String?, groups: [String]) -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        let prefix = teamID + "."
        return groups.first { $0.hasPrefix(prefix) && $0.count > prefix.count }
    }
}

/// The running process's signature: its team, and the App Groups it's entitled to.
private enum OwnSignature {
    static func teamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func appGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
    }
}
