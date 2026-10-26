import CryptoKit
import Foundation
import RelvoraCore
import Testing

@testable import RelvoraUpdates

/// A fake installed Relvora and fake downloaded zips in a temporary folder. The signature check is a stub; the real one
/// is in `CodeSignatureTests`.
private struct Sandbox {
    let root: URL
    let installed: URL

    init(installedVersion: String = "0.1.2") throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RelvoraUpdatesTests-\(UUID().uuidString)")
        let applications = root.appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        installed = applications.appending(path: "Relvora.app")
        try Self.makeApp(at: installed, version: installedVersion)
    }

    static func makeApp(at app: URL, version: String, bundleID: String = "com.example.Relvora") throws {
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(
            at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try Data("binary \(version)".utf8).write(to: contents.appending(path: "MacOS/Relvora"))
    }

    /// A zip like the release workflow's (`ditto -c -k --keepParent Relvora.app`).
    func zip(version: String, bundleID: String = "com.example.Relvora", extra: String? = nil) throws -> URL {
        let source = root.appending(path: "build-\(UUID().uuidString)", directoryHint: .isDirectory)
        try Self.makeApp(at: source.appending(path: "Relvora.app"), version: version, bundleID: bundleID)
        let binary = source.appending(path: "Relvora.app/Contents/MacOS/Relvora")
        setxattr(binary.path, "com.apple.quarantine", "0081;00000000;Test;", 19, 0, 0)
        if let extra { try Data("extra".utf8).write(to: source.appending(path: extra)) }
        let zip = root.appending(path: "Relvora-\(version)-\(UUID().uuidString).zip")
        // The folder's contents: the app, with `extra` beside it.
        try run("/usr/bin/ditto", ["-c", "-k", source.path, zip.path])
        return zip
    }

    func garbage() throws -> URL {
        let file = root.appending(path: "garbage.zip")
        try Data("not a zip".utf8).write(to: file)
        return file
    }

    func installedVersion() throws -> String? {
        try UpdateInstaller.infoPlist(of: installed)["CFBundleShortVersionString"] as? String
    }

    func install(
        _ zip: URL, version: String, sha256: String? = nil, signature: SignatureProblem? = nil
    ) throws(UpdateInstallError) {
        let installer = UpdateInstaller(installedApp: installed, disposal: .delete) { _ throws(SignatureProblem) in
            if let signature { throw signature }
        }
        let handle = try! FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        try installer.install(
            archive: handle, version: SemanticVersion(version)!, sha256: sha256 ?? Self.sha256(of: zip))
    }

    static func sha256(of file: URL) -> String {
        SHA256.hash(data: try! Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Suite("Update installer")
struct UpdateInstallerTests {
    @Test("A checked update replaces the installed app in place, without quarantine")
    func installs() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.install(try sandbox.zip(version: "0.2.0"), version: "0.2.0")
        #expect(try sandbox.installedVersion() == "0.2.0")
        let binary = sandbox.installed.appending(path: "Contents/MacOS/Relvora")
        #expect(String(decoding: try Data(contentsOf: binary), as: UTF8.self) == "binary 0.2.0")
        #expect(getxattr(binary.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1)
        // Only the app is left in its folder: no staging files, no previous version beside it.
        let folder = sandbox.installed.deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["Relvora.app"])
    }

    @Test(
        "Nothing changes when a check fails",
        arguments: [
            ("checksum", UpdateInstallError.checksumMismatch),
            ("signature", .signature("it isn’t signed")),
            ("bundle", .differentApp("com.example.Other")),
            ("version", .wrongVersion(found: "0.3.0")),
            ("older", .notNewer(found: "0.1.1")),
            ("same", .notNewer(found: "0.1.2")),
            ("two items", .unexpectedContents),
            ("garbage", .unreadableArchive),
        ])
    func refuses(failure: String, expected: UpdateInstallError) throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        #expect(throws: expected) {
            switch failure {
            case "checksum":
                try sandbox.install(
                    try sandbox.zip(version: "0.2.0"), version: "0.2.0", sha256: String(repeating: "0", count: 64))
            case "signature":
                try sandbox.install(
                    try sandbox.zip(version: "0.2.0"), version: "0.2.0",
                    signature: SignatureProblem(status: errSecCSUnsigned))
            case "bundle":
                try sandbox.install(try sandbox.zip(version: "0.2.0", bundleID: "com.example.Other"), version: "0.2.0")
            case "version":
                try sandbox.install(try sandbox.zip(version: "0.3.0"), version: "0.2.0")
            case "older":
                try sandbox.install(try sandbox.zip(version: "0.1.1"), version: "0.1.1")
            case "same":
                try sandbox.install(try sandbox.zip(version: "0.1.2"), version: "0.1.2")
            case "two items":
                try sandbox.install(try sandbox.zip(version: "0.2.0", extra: "README.txt"), version: "0.2.0")
            default:
                try sandbox.install(try sandbox.garbage(), version: "0.2.0")
            }
        }
        #expect(try sandbox.installedVersion() == "0.1.2")
        let folder = sandbox.installed.deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == ["Relvora.app"])
    }

    @Test("Relvora running from a temporary copy or a read-only disk can't replace itself")
    func locations() throws {
        let translocated = URL(filePath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/Relvora.app")
        #expect(UpdateLocation.problem(for: translocated)?.contains("temporary copy") == true)
        let installer = UpdateInstaller(installedApp: translocated, disposal: .delete) { _ throws(SignatureProblem) in }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let handle = try FileHandle(forReadingFrom: try sandbox.zip(version: "0.2.0"))
        defer { try? handle.close() }
        #expect {
            try installer.install(archive: handle, version: SemanticVersion("0.2.0")!, sha256: "")
        } throws: { error in
            guard case .notInstallable = error as? UpdateInstallError else { return false }
            return true
        }
        #expect(UpdateLocation.problem(for: sandbox.installed) == nil)
    }

    @Test("Errors cross the XPC connection unchanged")
    func xpcRoundTrip() {
        let errors: [UpdateInstallError] = [
            .notInstallable("x"), .unsigned, .checksumMismatch, .unreadableArchive, .unexpectedContents,
            .differentApp("com.example"), .wrongVersion(found: nil), .wrongVersion(found: "1.0.0"),
            .notNewer(found: "1.0.0"),
            .signature("y"), .replaceFailed("z"), .busy, .updaterUnavailable("w"),
        ]
        for error in errors {
            #expect(UpdateInstallError(xpcError: error.xpcError) == error)
        }
        let other = NSError(domain: NSCocoaErrorDomain, code: 4097)
        guard case .updaterUnavailable = UpdateInstallError(xpcError: other) else {
            Issue.record("A connection error is the updater not answering")
            return
        }
    }
}

@Suite("Relaunch")
struct RelaunchTests {
    @Test("A recent ticket is read once it's saved; an old one is ignored")
    func ticket() throws {
        let suite = "RelvoraUpdatesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ticket = RelaunchTicket(
            previousPID: 42, version: "0.2.0", backupPath: "/b/Before updating.json",
            arguments: ["-RelvoraDefaultsSuite", "com.example.shots", "-RelvoraInMemoryStore", "YES"], createdAt: now)
        ticket.save(to: defaults)
        #expect(RelaunchTicket.pending(in: defaults, now: now.addingTimeInterval(5)) == ticket)
        #expect(RelaunchTicket.pending(in: defaults, now: now.addingTimeInterval(61)) == nil)
        #expect(RelaunchTicket.pending(in: defaults, now: now.addingTimeInterval(-5)) == nil)
        RelaunchTicket.clear(in: defaults)
        #expect(RelaunchTicket.pending(in: defaults, now: now) == nil)
    }

    @Test("Launch options are read from the forwarded arguments")
    func options() {
        let ticket = RelaunchTicket(
            previousPID: 1, version: "1.0.0", backupPath: nil,
            arguments: ["-RelvoraDefaultsSuite", "com.example.shots", "-RelvoraInMemoryStore", "YES", "-Last"])
        #expect(ticket.option("RelvoraDefaultsSuite") == "com.example.shots")
        #expect(ticket.option("RelvoraInMemoryStore") == "YES")
        #expect(ticket.option("Last") == nil && ticket.option("Missing") == nil)
    }
}
