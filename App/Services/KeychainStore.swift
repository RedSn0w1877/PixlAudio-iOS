import Foundation
import Security

/// Generic-password Keychain storage for this app only (no access group — sideloaded builds can't share).
/// Items are readable after first unlock so background refreshes can use tokens.
nonisolated enum KeychainStore {
    nonisolated enum KeychainError: Error, Equatable, CustomStringConvertible {
        case status(OSStatus)
        case unexpectedData

        var description: String {
            switch self {
            case .status(let status): "Keychain error \(status)"
            case .unexpectedData: "Keychain returned unexpected data"
            }
        }
    }

    static let service = "io.github.redsn0w1877.pixlaudio"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Stores `data` for `account`, replacing any existing item.
    static func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Returns the data stored for `account`, or `nil` if there is none.
    static func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return data
    }

    /// Deletes the item for `account` (no error if it doesn't exist).
    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
