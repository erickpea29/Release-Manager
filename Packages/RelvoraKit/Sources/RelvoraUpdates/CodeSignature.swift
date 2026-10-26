import Foundation
import Security

/// Which signatures an update must have to be installed (ADR 0017).
public enum SigningPolicy: Sendable {
    /// Release builds: signed with Developer ID by the running app's team, with the running app's bundle ID, and
    /// notarized by Apple (the stapled ticket, or Apple's servers).
    case developerID
    /// Debug builds, for checking the installer locally: any Apple-issued certificate of the running app's team, with
    /// its bundle ID. Never used by Release builds.
    case development

    /// A code requirement (Code Signing Requirement Language). `nil` when the team or bundle ID has characters a team
    /// or bundle ID can't have, so nothing can be injected into the requirement.
    public func requirement(teamID: String, bundleID: String) -> String? {
        guard Self.isTeamID(teamID), Self.isBundleID(bundleID) else { return nil }
        let same =
            "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        switch self {
        case .developerID: return same + " and " + Self.developerIDRequirement + " and notarized"
        case .development: return same
        }
    }

    /// Apple's Developer ID requirement: the Developer ID intermediate and a Developer ID Application leaf certificate.
    public static let developerIDRequirement =
        "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    public static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    static func isBundleID(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return !text.isEmpty && text.count <= 255 && text.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Reads and checks code signatures with the Security framework.
public enum CodeSignature {
    /// Every architecture, nested code (the updater inside the app), the strict bundle checks `codesign --strict`
    /// makes, and no symbolic links that leave the bundle.
    static let validityFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSRestrictSymlinks
            | kSecCSAllowNetworkAccess)

    /// The team that signed the running process; `nil` when it's ad-hoc signed or unsigned.
    public static func ownTeamIdentifier() -> String? {
        guard let code = try? ownStaticCode() else { return nil }
        return teamIdentifier(of: code)
    }

    /// The team that signed the code at `url`; `nil` when it's ad-hoc signed or unsigned. Doesn't validate it.
    public static func teamIdentifier(ofCodeAt url: URL) -> String? {
        guard let code = try? staticCode(at: url) else { return nil }
        return teamIdentifier(of: code)
    }

    /// Whether the running process is signed with Developer ID, as Relvora's releases are. Checks the running
    /// signature, without reading the app's files again.
    public static func isOwnCodeDeveloperID() -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecRequirementCreateWithString(
                ("anchor apple generic and " + SigningPolicy.developerIDRequirement) as CFString, [], &requirement)
                == errSecSuccess
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Validates the code at `url`: its signature, every file it seals, and `requirement`.
    public static func check(_ url: URL, requirement: String) throws(SignatureProblem) {
        try check(try staticCode(at: url), requirement: requirement)
    }

    // MARK: Security framework

    private static func ownStaticCode() throws(SignatureProblem) -> SecStaticCode {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw SignatureProblem(status: status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw SignatureProblem(status: status) }
        return staticCode
    }

    private static func staticCode(at url: URL) throws(SignatureProblem) -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw SignatureProblem(status: status) }
        return code
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func check(_ code: SecStaticCode, requirement text: String) throws(SignatureProblem) {
        var requirement: SecRequirement?
        var status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw SignatureProblem(status: status) }
        var error: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, validityFlags, requirement, &error)
        error?.release()
        guard status == errSecSuccess else { throw SignatureProblem(status: status) }
    }
}

/// Why a signature check failed.
public struct SignatureProblem: Error, Sendable, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    /// Unsigned, or signed by someone else, or not notarized: the code doesn't meet the requirement.
    public var isRequirementFailure: Bool { status == errSecCSReqFailed || status == errSecCSUnsigned }

    public var description: String {
        switch status {
        case errSecCSUnsigned: return "it isn’t signed"
        case errSecCSReqFailed: return "it isn’t signed with Relvora’s Developer ID, or isn’t notarized by Apple"
        case errSecCSSignatureFailed, errSecCSBadResource, errSecCSResourcesNotSealed, errSecCSResourcesNotFound,
            errSecCSBadMainExecutable:
            return "its files don’t match their signature"
        default:
            let message = SecCopyErrorMessageString(status, nil) as String?
            return "its signature couldn’t be checked (\(message ?? "error \(status)"))"
        }
    }
}
