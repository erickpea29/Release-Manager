import Foundation
import LocalAuthentication
import Security

public enum KeychainFlavor: String, Sendable, CaseIterable {
    /// Legacy file-based keychain. ACLs are bound to the code signature's designated requirement.
    case fileBased
    /// iOS-style keychain. Needs an application-identifier / access-group entitlement.
    case dataProtection
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let operation: String
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(operation) failed: OSStatus \(status) (\(message))"
    }
}

/// Stores opaque secrets as generic passwords. Values are never logged or included in descriptions.
public struct KeychainCredentialStore: Sendable {
    public let service: String
    public let flavor: KeychainFlavor

    public init(service: String, flavor: KeychainFlavor) {
        self.service = service
        self.flavor = flavor
    }

    public func write(_ secret: Data, account: String) throws {
        try delete(account: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(operation: "SecItemAdd", status: status) }
    }

    /// With `allowUserInteraction: false`, an access that would need a keychain prompt fails with
    /// `errSecInteractionNotAllowed` instead of showing UI.
    public func read(account: String, allowUserInteraction: Bool = true) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(operation: "SecItemCopyMatching", status: status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "SecItemDelete", status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if flavor == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

public enum KeychainProbe {
    /// Writes, reads back, compares, and deletes a random non-secret value. Returns a human-readable verdict.
    public static func roundTrip(service: String, flavor: KeychainFlavor) -> String {
        let store = KeychainCredentialStore(service: service, flavor: flavor)
        let account = "m00-roundtrip-probe"
        let value = Data(UUID().uuidString.utf8)
        do {
            try store.write(value, account: account)
            let readBack = try store.read(account: account)
            try store.delete(account: account)
            let gone = try store.read(account: account) == nil
            return readBack == value && gone ? "PASS" : "FAIL (value mismatch or not deleted)"
        } catch {
            return "FAIL \(error)"
        }
    }
}
