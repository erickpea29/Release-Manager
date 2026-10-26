import Foundation
import Security

/// The key Claude Code sends with every request. Random, kept only in the Keychain and in the user's Claude Code
/// settings, and replaceable at any time.
public enum AccessKey {
    /// 32 random bytes, URL-safe Base64, with a prefix that says what it is: `rlv_…`.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes")
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "rlv_" + base64
    }

    public static func isWellFormed(_ key: String) -> Bool {
        key.hasPrefix("rlv_") && key.count >= 40
            && key.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
            }
    }
}

/// One generic-password item in the Keychain, like the GitHub sign-in (ADR 0005).
public struct KeychainAccessKeyStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.erickpea29.Relvora.claude", account: String = "access-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or a new one saved first.
    public func loadOrCreate() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8),
            AccessKey.isWellFormed(key)
        {
            return key
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        return try replace()
    }

    /// Saves a new key, so the previous one stops working.
    @discardableResult
    public func replace() throws -> String {
        let key = AccessKey.generate()
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return key }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "The Keychain refused (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
    }
}
