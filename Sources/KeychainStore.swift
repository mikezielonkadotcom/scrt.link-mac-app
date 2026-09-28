import Foundation
import Security

enum KeychainStore {
    private static let service = "com.mikezielonka.scrt-link"
    // Reuse the account name from the original Keychain-backed builds.
    private static let account = "apiToken"
    private static let legacyDefaultsKey = "scrtLinkApiToken"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static var apiToken: String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }

        // Migrate only when the item is absent. A Keychain access error must
        // never silently make the app fall back to a less protected store.
        guard status == errSecItemNotFound,
              let legacyToken = UserDefaults.standard.string(forKey: legacyDefaultsKey),
              !legacyToken.isEmpty else { return "" }
        do {
            try setApiToken(legacyToken)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            return legacyToken
        } catch {
            return ""
        }
    }

    static var hasToken: Bool { !apiToken.isEmpty }

    static func setApiToken(_ token: String) throws {
        let status: OSStatus
        if token.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
        } else {
            let data = Data(token.utf8)
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            } else if status != errSecSuccess {
                throw KeychainError(status: status)
            }
        }

        // Remove any pre-Keychain copy only after the Keychain operation succeeds.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        NotificationCenter.default.post(name: .apiTokenChanged, object: nil)
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
            return "Could not save the API token in Keychain: \(message) (\(status))."
        }
    }
}

extension Notification.Name {
    static let apiTokenChanged = Notification.Name("scrtLinkApiTokenChanged")
}
