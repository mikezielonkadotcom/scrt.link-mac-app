import Foundation
import Security

// Regression tests for KeychainStore, compiled by tests/test-keychain-store.sh
// together with Sources/KeychainStore.swift only.
//
// Isolation:
//   - KeychainStore.service points at a throwaway service unique to this run,
//     so the app's real `com.mikezielonka.scrt-link` item is never read or
//     changed. Every test item is deleted before exit.
//   - An unbundled binary gets its own UserDefaults domain (named after the
//     executable), so the legacy-token key never touches the app's defaults.
//   - Keychain user interaction is disabled: a locked keychain fails fast
//     instead of showing a password prompt.
// Token values here are fake and are never printed.

SecKeychainSetUserInteractionAllowed(false)

let service = "com.mikezielonka.scrt-link.tests.\(UUID().uuidString)"
KeychainStore.service = service
let legacyKey = "scrtLinkApiToken"
let defaults = UserDefaults.standard

var failures = 0
var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (line \(line))")
    }
}

/// Reads the test item directly, bypassing KeychainStore.
@MainActor
func keychainValue() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "apiToken",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

@MainActor
func resetState() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
    defaults.removeObject(forKey: legacyKey)
}

resetState()
defer { resetState() }

print("▸ No token anywhere")
check(KeychainStore.apiToken == "", "apiToken is empty")
check(!KeychainStore.hasToken, "hasToken is false")

print("")
print("▸ Legacy UserDefaults token, no Keychain item")
defaults.set("fake-token-legacy", forKey: legacyKey)
check(KeychainStore.apiToken == "fake-token-legacy", "legacy token is returned")
check(defaults.string(forKey: legacyKey) == nil, "plaintext UserDefaults copy is removed")
check(keychainValue() == "fake-token-legacy", "token now lives in Keychain")

print("")
print("▸ Save and clear through setApiToken")
do {
    try KeychainStore.setApiToken("fake-token-saved")
    check(keychainValue() == "fake-token-saved", "saved token updates the Keychain item")
    check(KeychainStore.apiToken == "fake-token-saved", "apiToken reads the saved token")
    try KeychainStore.setApiToken("")
    check(keychainValue() == nil, "clearing deletes the Keychain item")
    check(!KeychainStore.hasToken, "hasToken is false after clearing")
} catch {
    check(false, "setApiToken threw: \(error.localizedDescription)")
}

print("")
print("▸ Keychain item plus a newer legacy token (rollback to 1.6.0, then forward)")
// 1.6.0 and older only read and write UserDefaults. After a rollback the user
// re-enters a (possibly rotated) token there. Builds with Keychain storage
// never write UserDefaults, so a legacy value is always the newest token.
do {
    try KeychainStore.setApiToken("fake-token-before-rollback")
    defaults.set("fake-token-after-rollback", forKey: legacyKey)
    check(KeychainStore.apiToken == "fake-token-after-rollback",
          "newer legacy token wins over the stale Keychain value")
    check(defaults.string(forKey: legacyKey) == nil,
          "plaintext UserDefaults copy is removed even when a Keychain item exists")
    check(keychainValue() == "fake-token-after-rollback",
          "Keychain item is updated to the newer token")
} catch {
    check(false, "setApiToken threw: \(error.localizedDescription)")
}

print("")
print("═══════════════════════════════════════════")
print("  Checks: \(checks)   Failed: \(failures)")
print("═══════════════════════════════════════════")
resetState()
exit(failures == 0 ? 0 : 1)
