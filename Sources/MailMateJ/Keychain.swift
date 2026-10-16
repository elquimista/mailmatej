import Foundation
import Security
import os

/// Account secrets (passwords, API tokens), keyed by local account id.
///
/// All secrets live in ONE keychain item (a JSON dictionary), read once per launch. Self-signed
/// builds have no Team ID, so macOS ties keychain access to the exact binary and asks again after
/// every update; with one item that is at most one prompt per update instead of one per account.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "app.mailmatej.MailMateJ") + ".secrets"
    private static let itemAccount = "accounts"
    /// Per-account items written by earlier builds; migrated into the single item on first read.
    private static let legacyService = "app.mailmatej.account"

    private static let state = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

    static func set(_ secret: String, account: String) throws {
        try state.withLock { secrets in
            var all = try secrets ?? loadAll()
            all[account] = secret
            try saveAll(all)
            secrets = all
        }
    }

    static func get(account: String) throws -> String {
        try state.withLock { secrets in
            var all = try secrets ?? loadAll()
            if all[account] == nil, let legacy = readLegacy(account: account) {
                all[account] = legacy
                try saveAll(all)
                deleteLegacy(account: account)
            }
            secrets = all
            guard let secret = all[account] else { throw KeychainError(status: errSecItemNotFound) }
            return secret
        }
    }

    static func delete(account: String) {
        state.withLock { secrets in
            guard var all = try? secrets ?? loadAll() else { return }
            all[account] = nil
            try? saveAll(all)
            secrets = all
        }
        deleteLegacy(account: account)
    }

    // MARK: Storage

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemAccount,
        ]
    }

    private static func loadAll() throws -> [String: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveAll(_ secrets: [String: String]) throws {
        let data = try JSONEncoder().encode(secrets)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MailMateJ accounts"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func readLegacy(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func deleteLegacy(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, CustomStringConvertible, LocalizedError {
    let status: OSStatus
    var description: String {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
    var errorDescription: String? {
        status == errSecItemNotFound
            ? "This account’s password isn’t in the keychain. Remove the account and add it again."
            : "Couldn’t access the keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
    }
}
