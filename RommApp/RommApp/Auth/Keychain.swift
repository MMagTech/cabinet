import Foundation
import Security

/// Minimal Keychain wrapper for the one secret this app holds, the access token.
///
/// Tokens are keyed by server host, so pairing with a second instance does not
/// clobber the first. Nothing else belongs in here. The server address is not
/// a secret and lives in UserDefaults.
enum Keychain {
    private static let service = "com.mmagtech.RommApp.accessToken"

    static func save(token: String, forHost host: String) throws {
        let data = Data(token.utf8)

        // Delete first, because SecItemAdd fails rather than replaces.
        SecItemDelete(query(host: host) as CFDictionary)

        var attributes = query(host: host)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    static func token(forHost host: String) -> String? {
        var lookup = query(host: host)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(forHost host: String) {
        SecItemDelete(query(host: host) as CFDictionary)
    }

    private static func query(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    enum KeychainError: LocalizedError {
        case unexpected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpected(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String?
                return "Could not save to the keychain. \(detail ?? "Code \(status).")"
            }
        }
    }
}
