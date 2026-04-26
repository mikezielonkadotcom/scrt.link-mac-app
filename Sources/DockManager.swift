import AppKit

@MainActor
enum DockManager {
    private static let key = "showInDock"

    static func apply() {
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        applyActivationPolicy(show: isShowingInDock)
    }

    /// Set the persisted preference AND apply it. Used by the Preferences UI.
    static func setDockVisibility(show: Bool) {
        UserDefaults.standard.set(show, forKey: key)
        applyActivationPolicy(show: show)
    }

    static var isShowingInDock: Bool {
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Change the activation policy without persisting. Used to transiently
    /// hide the Dock icon when the main window is closed (so the app lives
    /// in the menu bar) and to restore it when the window reopens.
    static func applyActivationPolicy(show: Bool) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        NSApp.setActivationPolicy(policy)

        if !show {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
