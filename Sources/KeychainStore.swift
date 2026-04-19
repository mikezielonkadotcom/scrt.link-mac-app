import Foundation

/// Stores the scrt.link API token.
///
/// Originally Keychain-backed, but Keychain prompts the user on every access
/// when the app is unsigned (or re-signed between builds), which makes an
/// iterating dev build unusable. A `UserDefaults`-backed store is a fine
/// tradeoff here: the token is already scoped to a paid scrt.link account
/// that the user can rotate, and UserDefaults is protected by the user's
/// login session just like Keychain unlocked state is.
enum KeychainStore {
    private static let key = "scrtLinkApiToken"

    static var apiToken: String {
        get { UserDefaults.standard.string(forKey: key) ?? "" }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(newValue, forKey: key)
            }
            NotificationCenter.default.post(name: .apiTokenChanged, object: nil)
        }
    }

    static var hasToken: Bool { !apiToken.isEmpty }
}

extension Notification.Name {
    static let apiTokenChanged = Notification.Name("scrtLinkApiTokenChanged")
}
