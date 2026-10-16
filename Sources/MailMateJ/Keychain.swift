import Foundation
import Security
import os

/// Account secrets (passwords, API tokens) in the login keychain, keyed by local account id.
enum Keychain {
    private static let service = "app.mailmatej.account"
    /// Secrets already read this launch. Each keychain read can show an access prompt, so read once.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: String]())

    static func set(_ secret: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrLabel as String] = "MailMateJ account"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cache.withLock { $0[account] = secret }
    }

    static func get(account: String) throws -> String {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        let secret = String(decoding: data, as: UTF8.self)
        cache.withLock { $0[account] = secret }
        return secret
    }

    static func delete(account: String) {
        cache.withLock { $0[account] = nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}
