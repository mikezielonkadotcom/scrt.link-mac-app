import AppKit
import ServiceManagement

@MainActor
class PreferencesWindow {
    private var window: NSWindow!
    private weak var webViewController: WebViewController?
    private var dockCheckbox: NSButton!
    private var loginCheckbox: NSButton!

    init(webViewController: WebViewController) {
        self.webViewController = webViewController
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scrt.link Preferences"
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        var y = 270

        // ========== GENERAL SECTION ==========
        let generalTitle = NSTextField(labelWithString: "General")
        generalTitle.font = NSFont.boldSystemFont(ofSize: 13)
        generalTitle.frame = NSRect(x: 20, y: y, width: 380, height: 20)
        contentView.addSubview(generalTitle)
        y -= 28

        loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(loginToggleChanged))
        loginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        loginCheckbox.frame = NSRect(x: 20, y: y, width: 380, height: 24)
        contentView.addSubview(loginCheckbox)
        y -= 22

        let loginDescription = NSTextField(labelWithString: "Automatically start Scrt.link when you log in.")
        loginDescription.font = NSFont.systemFont(ofSize: 11)
        loginDescription.textColor = .secondaryLabelColor
        loginDescription.frame = NSRect(x: 20, y: y, width: 380, height: 18)
        contentView.addSubview(loginDescription)
        y -= 26

        dockCheckbox = NSButton(checkboxWithTitle: "Show in Dock", target: self, action: #selector(dockToggleChanged))
        dockCheckbox.state = DockManager.isShowingInDock ? .on : .off
        dockCheckbox.frame = NSRect(x: 20, y: y, width: 380, height: 24)
        contentView.addSubview(dockCheckbox)
        y -= 22

        let dockDescription = NSTextField(labelWithString: "When enabled, the app icon appears in the Dock.")
        dockDescription.font = NSFont.systemFont(ofSize: 11)
        dockDescription.textColor = .secondaryLabelColor
        dockDescription.frame = NSRect(x: 20, y: y, width: 380, height: 18)
        contentView.addSubview(dockDescription)
        y -= 30

        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.frame = NSRect(x: 20, y: y, width: 380, height: 1)
        contentView.addSubview(sep1)
        y -= 24

        // ========== DATA SECTION ==========
        let clearButton = NSButton(title: "Clear Website Data", target: self, action: #selector(clearData))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 20, y: y, width: 160, height: 28)
        contentView.addSubview(clearButton)
        y -= 22

        let clearDescription = NSTextField(labelWithString: "Clears cookies and cache. You will need to log in again.")
        clearDescription.font = NSFont.systemFont(ofSize: 11)
        clearDescription.textColor = .secondaryLabelColor
        clearDescription.frame = NSRect(x: 20, y: y, width: 380, height: 18)
        contentView.addSubview(clearDescription)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let versionLabel = NSTextField(labelWithString: "Scrt.link v\(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.frame = NSRect(x: 20, y: 12, width: 380, height: 18)
        contentView.addSubview(versionLabel)

        window.contentView = contentView
    }

    func showWindow() {
        dockCheckbox.state = DockManager.isShowingInDock ? .on : .off
        loginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Launch at Login

    private func isLaunchAtLoginEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func loginToggleChanged() {
        let enable = loginCheckbox.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not \(enable ? "enable" : "disable") Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            loginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        }
    }

    // MARK: - Dock

    @objc private func dockToggleChanged() {
        let show = dockCheckbox.state == .on
        DockManager.setDockVisibility(show: show)
    }

    // MARK: - Clear Data

    @objc private func clearData() {
        let alert = NSAlert()
        alert.messageText = "Clear Website Data?"
        alert.informativeText = "This will clear all cookies and cached data. You will need to log back in to Scrt.link."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            webViewController?.clearWebsiteData()
        }
    }
}
