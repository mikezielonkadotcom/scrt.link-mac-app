import Foundation
import Security

enum KeychainStore {
    /// Keychain service that holds the token. Tests point this at a
    /// throwaway service so they never read, or prompt for, the app's item.
    nonisolated(unsafe) static var service = "com.mikezielonka.scrt-link"
    // Reuse the account name from the original Keychain-backed builds.
    private static let account = "apiToken"
    private static let legacyDefaultsKey = "scrtLinkApiToken"

    /// Last value read from or written to Keychain in this process. Avoids a
    /// Keychain round trip for every `hasToken` check; `setApiToken` keeps it
    /// current, and a legacy UserDefaults value still takes precedence below.
    /// Like `service`, this is only touched from the main thread.
    nonisolated(unsafe) private static var cachedToken: String?

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static var apiToken: String {
        // Builds with Keychain storage never write UserDefaults, so a legacy
        // value was written by an older build, for example after a rollback
        // to 1.6.0, and is the newest token. Move it into Keychain even when
        // an item already exists, so no plaintext copy is left behind.
        if let legacyToken = UserDefaults.standard.string(forKey: legacyDefaultsKey), !legacyToken.isEmpty {
            if (try? setApiToken(legacyToken)) != nil { return legacyToken }
        }
        if let cachedToken { return cachedToken }
        let token = readKeychainToken()
        if let token { cachedToken = token }
        return token ?? ""
    }

    /// The Keychain value, "" when there is no item, or nil on an access
    /// error (which is deliberately not cached so the next read retries).
    private static func readKeychainToken() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let stored: String? = status == errSecSuccess
            ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil

        // A Keychain access error must never silently make the app fall back
        // to a less protected store.
        guard status == errSecSuccess || status == errSecItemNotFound else { return nil }
        return stored ?? ""
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
        cachedToken = token
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
