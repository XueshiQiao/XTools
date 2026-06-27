import Foundation
import Security

/// Resolves the app's first `keychain-access-groups` entitlement at runtime, so
/// we use the data-protection keychain (no per-binary ACL → no "wants to access
/// the keychain" prompt). Returns nil for unsigned/dev builds without the
/// entitlement, in which case `KeychainStore` falls back to the legacy keychain
/// rather than silently breaking persistence.
enum KeychainAccessGroup {
    static var resolved: String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task, "keychain-access-groups" as CFString, nil) as? [String],
              let first = groups.first
        else { return nil }
        return first
    }
}

enum KeychainError: Error { case unexpectedData; case unhandled(OSStatus) }

/// Minimal generic-password store, set up the way that avoids the TCC prompt:
/// data-protection keychain + access group when the entitlement is present.
struct KeychainStore {
    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = KeychainAccessGroup.resolved {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    /// Read a stored string, or nil if absent.
    func get(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    /// Store (or update) a string. Surfaces the `OSStatus` — never swallowed.
    func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unexpectedData }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        default:
            throw KeychainError.unhandled(updateStatus)
        }
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
