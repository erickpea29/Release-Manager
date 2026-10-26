import Foundation

/// Why an update wasn't installed. Crosses the XPC connection as an `NSError` (`code` and `detail`).
public enum UpdateInstallError: Error, Sendable, Equatable, LocalizedError {
    /// Relvora runs from somewhere it can't replace itself: a disk image, a quarantined copy macOS moved, a folder
    /// without write access.
    case notInstallable(String)
    /// This copy of Relvora isn't signed by a team, so there's no signature to compare the update with.
    case unsigned
    case checksumMismatch
    case unreadableArchive
    /// The zip doesn't hold exactly one app, or holds paths that leave its folder.
    case unexpectedContents
    /// The app in the zip isn't Relvora: another bundle ID.
    case differentApp(String)
    case wrongVersion(found: String?)
    /// The app in the zip isn't newer than the installed one.
    case notNewer(found: String)
    case signature(String)
    case replaceFailed(String)
    /// Another update is being installed.
    case busy
    /// The updater inside Relvora didn't answer.
    case updaterUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notInstallable(let reason): "Relvora can’t replace itself: \(reason)."
        case .unsigned: "This copy of Relvora isn’t signed, so it can’t check the update’s signature."
        case .checksumMismatch: "The download doesn’t match the checksum published with the release."
        case .unreadableArchive: "The update couldn’t be unpacked."
        case .unexpectedContents: "The update doesn’t contain just the Relvora app."
        case .differentApp(let bundleID): "The update is a different app (\(bundleID))."
        case .wrongVersion(let found):
            "The update is \(found.map { "version \($0)" } ?? "an unknown version"), not the version offered."
        case .notNewer(let found): "The update (\(found)) isn’t newer than this Relvora."
        case .signature(let reason): "The update’s signature isn’t trusted: \(reason)."
        case .replaceFailed(let reason): "Relvora couldn’t replace itself: \(reason)."
        case .busy: "Another update is being installed."
        case .updaterUnavailable(let reason): "Relvora’s updater didn’t respond (\(reason))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notInstallable, .replaceFailed:
            "Download the update from the release page and replace Relvora in Applications yourself."
        case .unsigned:
            "Install a release build of Relvora, signed with Developer ID."
        case .checksumMismatch, .unreadableArchive:
            "Try again. If it happens again, download the update from the release page."
        case .unexpectedContents, .differentApp, .wrongVersion, .notNewer, .signature:
            "Nothing was installed. Check the release on GitHub before installing it yourself."
        case .busy, .updaterUnavailable:
            "Try again in a moment."
        }
    }

    // MARK: XPC

    public static let errorDomain = "com.erickpea29.Relvora.UpdateInstallError"

    private var code: Int {
        switch self {
        case .notInstallable: 1
        case .unsigned: 2
        case .checksumMismatch: 3
        case .unreadableArchive: 4
        case .unexpectedContents: 5
        case .differentApp: 6
        case .wrongVersion: 7
        case .notNewer: 8
        case .signature: 9
        case .replaceFailed: 10
        case .busy: 11
        case .updaterUnavailable: 12
        }
    }

    private var detail: String? {
        switch self {
        case .notInstallable(let text), .differentApp(let text), .notNewer(let text), .signature(let text),
            .replaceFailed(let text), .updaterUnavailable(let text):
            text
        case .wrongVersion(let found): found
        case .unsigned, .checksumMismatch, .unreadableArchive, .unexpectedContents, .busy: nil
        }
    }

    public var xpcError: NSError {
        NSError(domain: Self.errorDomain, code: code, userInfo: detail.map { ["detail": $0] } ?? [:])
    }

    /// The error an `xpcError` describes; anything else is the updater not answering properly.
    public init(xpcError error: NSError) {
        let detail = error.userInfo["detail"] as? String
        guard error.domain == Self.errorDomain else {
            self = .updaterUnavailable(error.localizedDescription)
            return
        }
        switch error.code {
        case 1: self = .notInstallable(detail ?? "unknown reason")
        case 2: self = .unsigned
        case 3: self = .checksumMismatch
        case 4: self = .unreadableArchive
        case 5: self = .unexpectedContents
        case 6: self = .differentApp(detail ?? "unknown")
        case 7: self = .wrongVersion(found: detail)
        case 8: self = .notNewer(found: detail ?? "unknown")
        case 9: self = .signature(detail ?? "unknown reason")
        case 10: self = .replaceFailed(detail ?? "unknown reason")
        case 11: self = .busy
        default: self = .updaterUnavailable(detail ?? "error \(error.code)")
        }
    }
}
