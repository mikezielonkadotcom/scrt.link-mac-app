import Foundation

enum Preferences {
    private static let useWebUIKey = "useWebUI"
    private static let customHostKey = "scrtLinkCustomHost"

    /// When false (default), the main window shows the native AppKit form that
    /// calls scrt.link's API via their client module. When true, the window
    /// embeds the scrt.link site directly in a WKWebView.
    static var useWebUI: Bool {
        get { UserDefaults.standard.bool(forKey: useWebUIKey) }
        set { UserDefaults.standard.set(newValue, forKey: useWebUIKey) }
    }

    /// Optional custom domain for white-labeled secret links. When set to
    /// e.g. "secrets.yourdomain.com", created links resolve to that domain
    /// instead of scrt.link. Requires scrt.link's Secret Service tier and a
    /// domain configured on their side — wrong-value in this field will
    /// cause the API call to fail at the host.
    static var customHost: String {
        get { UserDefaults.standard.string(forKey: customHostKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: customHostKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: customHostKey)
            }
        }
    }
}
