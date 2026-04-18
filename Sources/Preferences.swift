import Foundation

enum Preferences {
    private static let useWebUIKey = "useWebUI"

    /// When false (default), the main window shows the native AppKit form that
    /// calls scrt.link's API via their client module. When true, the window
    /// embeds the scrt.link site directly in a WKWebView.
    static var useWebUI: Bool {
        get { UserDefaults.standard.bool(forKey: useWebUIKey) }
        set { UserDefaults.standard.set(newValue, forKey: useWebUIKey) }
    }
}
