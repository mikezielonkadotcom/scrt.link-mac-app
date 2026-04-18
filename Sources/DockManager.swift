import AppKit

@MainActor
enum DockManager {
    private static let key = "showInDock"

    static func apply() {
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        let show = UserDefaults.standard.bool(forKey: key)
        setPolicy(show: show)
    }

    static func setDockVisibility(show: Bool) {
        UserDefaults.standard.set(show, forKey: key)
        setPolicy(show: show)
    }

    static var isShowingInDock: Bool {
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func setPolicy(show: Bool) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        NSApp.setActivationPolicy(policy)

        if !show {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
