import CoreServices
import CryptoKit
import Foundation
import RelvoraCore
import os

/// Replaces the installed Relvora with a downloaded one, only after checking it (ADR 0017):
///
/// 1. The zip matches the checksum the app checked against the release, and holds one app and nothing outside it.
/// 2. The app has the installed app's bundle ID, is the version offered, and is newer.
/// 3. Its signature meets the `SigningPolicy`: in Release builds, Developer ID, the same team as the running app, and
///    notarized.
/// 4. Only then is it swapped in, in one atomic step, and the previous version goes to the Trash.
///
/// Runs in the updater service, outside the app's sandbox (a sandboxed app can't replace itself). Package tests run it
/// on temporary folders.
public struct UpdateInstaller: Sendable {
    public enum Disposal: Sendable {
        /// The previous version goes to the Trash, so it can be put back.
        case trash
        /// The previous version is deleted (tests).
        case delete
    }

    public typealias SignatureCheck = @Sendable (URL) throws(SignatureProblem) -> Void

    /// The app to replace.
    public let installedApp: URL
    private let disposal: Disposal
    private let checkSignature: SignatureCheck

    /// Far above Relvora's size (about 5 MB), so a wrong download can't fill the disk.
    static let maximumArchiveSize: UInt64 = 512 << 20

    public init(installedApp: URL, disposal: Disposal = .trash, checkSignature: @escaping SignatureCheck) {
        self.installedApp = installedApp
        self.disposal = disposal
        self.checkSignature = checkSignature
    }

    /// The installer for the app that contains `service` (`Relvora.app/Contents/XPCServices/…`), checking signatures
    /// against the running service's own team, which is the app's.
    public static func forHostApp(of service: Bundle = .main, policy: SigningPolicy) throws(UpdateInstallError)
        -> UpdateInstaller
    {
        let services = service.bundleURL.deletingLastPathComponent()
        let app = services.deletingLastPathComponent().deletingLastPathComponent()
        guard services.lastPathComponent == "XPCServices", app.pathExtension == "app" else {
            throw .notInstallable("its updater isn’t inside the app")
        }
        guard let teamID = CodeSignature.ownTeamIdentifier() else { throw .unsigned }
        guard let bundleID = (try? infoPlist(of: app))?["CFBundleIdentifier"] as? String,
            let requirement = policy.requirement(teamID: teamID, bundleID: bundleID)
        else { throw .notInstallable("its bundle ID can’t be read") }
        return UpdateInstaller(installedApp: app) { url throws(SignatureProblem) in
            try CodeSignature.check(url, requirement: requirement)
        }
    }

    /// Checks the zip read from `archive` and installs the app in it. Returns where the previous version went in the
    /// Trash, if it went there. Nothing changes unless every check passes.
    @discardableResult
    public func install(archive: FileHandle, version: SemanticVersion, sha256: String) throws(UpdateInstallError)
        -> URL?
    {
        if let problem = UpdateLocation.problem(for: installedApp) { throw .notInstallable(problem) }
        let folder = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw .notInstallable("you can’t make changes in “\(folder.path)”")
        }
        let installed: [String: Any]
        do {
            installed = try Self.infoPlist(of: installedApp)
        } catch {
            throw .notInstallable("its Info.plist can’t be read")
        }

        // On the same disk as the app, so the swap is a rename.
        let staging: URL
        do {
            staging = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installedApp, create: true)
        } catch {
            throw .notInstallable("there’s no temporary folder on its disk")
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let zip = staging.appending(path: "update.zip")
        guard try Self.copy(archive, to: zip) == sha256.lowercased() else { throw .checksumMismatch }
        try Self.checkEntries(of: zip)
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        try Self.unpack(zip, into: unpacked)
        let update = try Self.singleApp(in: unpacked)

        let info: [String: Any]
        do {
            info = try Self.infoPlist(of: update)
        } catch {
            throw .unexpectedContents
        }
        let bundleID = info["CFBundleIdentifier"] as? String
        guard bundleID == installed["CFBundleIdentifier"] as? String else {
            throw .differentApp(bundleID ?? "no bundle ID")
        }
        let found = info["CFBundleShortVersionString"] as? String
        guard let foundVersion = found.flatMap(SemanticVersion.init), foundVersion == version else {
            throw .wrongVersion(found: found)
        }
        if let current = (installed["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
            foundVersion <= current
        {
            throw .notNewer(found: foundVersion.description)
        }
        do {
            try checkSignature(update)
        } catch {
            throw .signature(error.description)
        }

        Self.removeQuarantine(in: update)
        try Self.swap(update, installedApp)
        // `update` now holds the previous version.
        let previous = dispose(update)
        LSRegisterURL(installedApp as CFURL, true)
        Log.updates.notice("Installed version \(foundVersion.description, privacy: .public)")
        return previous
    }

    // MARK: Steps

    /// Copies the archive into the staging folder and returns its SHA-256, so the checked bytes are the ones unpacked.
    private static func copy(_ archive: FileHandle, to url: URL) throws(UpdateInstallError) -> String {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw .notInstallable("a temporary file can’t be written")
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var hasher = SHA256()
            var size: UInt64 = 0
            while let chunk = try archive.read(upToCount: 1 << 20), !chunk.isEmpty {
                size += UInt64(chunk.count)
                guard size <= maximumArchiveSize else { throw UpdateInstallError.unreadableArchive }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw .unreadableArchive
        }
    }

    /// Every entry is inside one top-level `.app` folder: no absolute paths, no `..`. ditto keeps file metadata
    /// (extended attributes) in `._name` entries, and sometimes a `__MACOSX` folder; unpacking turns those back into
    /// metadata.
    private static func checkEntries(of zip: URL) throws(UpdateInstallError) {
        guard let listing = run("/usr/bin/zipinfo", ["-1", zip.path]) else { throw .unreadableArchive }
        let names = listing.split(whereSeparator: \.isNewline)
        let tops = Set(names.map { $0.split(separator: "/", omittingEmptySubsequences: false).first ?? "" })
            .filter { !$0.hasPrefix("._") && $0 != "__MACOSX" }
        guard !names.isEmpty, tops.count == 1, let top = tops.first, top.hasSuffix(".app"),
            names.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw .unexpectedContents }
    }

    private static func unpack(_ zip: URL, into folder: URL) throws(UpdateInstallError) {
        // `--noqtn`: the copy isn't quarantined; its signature was checked instead.
        guard run("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, folder.path]) != nil else {
            throw .unreadableArchive
        }
    }

    private static func singleApp(in folder: URL) throws(UpdateInstallError) -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard items.count == 1, let app = items.first, app.pathExtension == "app",
            let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { throw .unexpectedContents }
        return app
    }

    static func infoPlist(of app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return plist
    }

    private static func removeQuarantine(in app: URL) {
        removexattr(app.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        let items = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil, options: [])
        while let item = items?.nextObject() as? URL {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Exchanges the two folders in one step: the app is never missing or half-copied.
    private static func swap(_ update: URL, _ installed: URL) throws(UpdateInstallError) {
        guard renamex_np(update.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            let reason = String(cString: strerror(code))
            Log.updates.error("Swap failed: \(reason, privacy: .public)")
            throw .replaceFailed(
                code == EPERM || code == EACCES
                    ? "macOS didn’t allow changes to “\(installed.lastPathComponent)” (\(reason))" : reason)
        }
    }

    private func dispose(_ previous: URL) -> URL? {
        if disposal == .trash {
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: previous, resultingItemURL: &trashed)) != nil {
                return trashed as URL?
            }
        }
        try? FileManager.default.removeItem(at: previous)
        return nil
    }

    /// Runs a system tool; returns its output, or `nil` when it fails.
    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Log.updates.error("\(tool, privacy: .public) exited with \(process.terminationStatus)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where Relvora can't replace itself, as far as the sandboxed app can tell (it can't test write access; the updater
/// does).
public enum UpdateLocation {
    public static func problem(for app: URL) -> String? {
        // App Translocation: a quarantined app opened from where it was downloaded runs from a read-only copy.
        if app.path.contains("/AppTranslocation/") {
            return "macOS runs it from a temporary copy. Move Relvora to the Applications folder, then open it again"
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "it runs from a read-only disk, such as a disk image"
        }
        return nil
    }
}

enum Log {
    /// Never logs tokens or file contents.
    static let updates = Logger(subsystem: "com.erickpea29.Relvora", category: "updates")
}
