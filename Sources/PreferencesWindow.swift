import AppKit
import ServiceManagement

@MainActor
class PreferencesWindow {
    private var window: NSWindow!
    private weak var webViewController: WebViewController?
    private var dockCheckbox: NSButton!
    private var loginCheckbox: NSButton!
    private var useWebUICheckbox: NSButton!
    private var apiTokenField: NSSecureTextField!
    private var customHostField: NSTextField!
    private var shortcutRecorder: ShortcutRecorderView!

    init(webViewController: WebViewController) {
        self.webViewController = webViewController
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scrt.link Preferences"
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        var y = 590

        // ========== GENERAL ==========
        let generalTitle = NSTextField(labelWithString: "General")
        generalTitle.font = NSFont.boldSystemFont(ofSize: 13)
        generalTitle.frame = NSRect(x: 20, y: y, width: 420, height: 20)
        contentView.addSubview(generalTitle)
        y -= 28

        loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(loginToggleChanged))
        loginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        loginCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 24)
        contentView.addSubview(loginCheckbox)
        y -= 22

        let loginDescription = NSTextField(labelWithString: "Automatically start Scrt.link when you log in.")
        loginDescription.font = NSFont.systemFont(ofSize: 11)
        loginDescription.textColor = .secondaryLabelColor
        loginDescription.frame = NSRect(x: 20, y: y, width: 420, height: 18)
        contentView.addSubview(loginDescription)
        y -= 26

        dockCheckbox = NSButton(checkboxWithTitle: "Show in Dock", target: self, action: #selector(dockToggleChanged))
        dockCheckbox.state = DockManager.isShowingInDock ? .on : .off
        dockCheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 24)
        contentView.addSubview(dockCheckbox)
        y -= 22

        let dockDescription = NSTextField(labelWithString: "When enabled, the app icon appears in the Dock.")
        dockDescription.font = NSFont.systemFont(ofSize: 11)
        dockDescription.textColor = .secondaryLabelColor
        dockDescription.frame = NSRect(x: 20, y: y, width: 420, height: 18)
        contentView.addSubview(dockDescription)
        y -= 30

        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.frame = NSRect(x: 20, y: y, width: 420, height: 1)
        contentView.addSubview(sep1)
        y -= 20

        // ========== KEYBOARD SHORTCUT ==========
        let shortcutTitle = NSTextField(labelWithString: "Global Hotkey")
        shortcutTitle.font = NSFont.boldSystemFont(ofSize: 13)
        shortcutTitle.frame = NSRect(x: 20, y: y, width: 420, height: 20)
        contentView.addSubview(shortcutTitle)
        y -= 28

        shortcutRecorder = ShortcutRecorderView()
        shortcutRecorder.shortcut = Preferences.shortcut
        shortcutRecorder.onChange = { newValue in
            Preferences.shortcut = newValue
        }
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = false
        shortcutRecorder.frame = NSRect(x: 20, y: y - 4, width: 420, height: 28)
        contentView.addSubview(shortcutRecorder)
        y -= 34

        let shortcutDesc = NSTextField(labelWithString: "Press the shortcut to open a new secret from anywhere with\nthe clipboard prefilled. Default: ⇧⌘S. Disable or reset above.")
        shortcutDesc.font = NSFont.systemFont(ofSize: 11)
        shortcutDesc.textColor = .secondaryLabelColor
        shortcutDesc.maximumNumberOfLines = 2
        shortcutDesc.frame = NSRect(x: 20, y: y - 4, width: 420, height: 30)
        contentView.addSubview(shortcutDesc)
        y -= 30

        let sepShortcut = NSBox()
        sepShortcut.boxType = .separator
        sepShortcut.frame = NSRect(x: 20, y: y, width: 420, height: 1)
        contentView.addSubview(sepShortcut)
        y -= 20

        // ========== API ==========
        let apiTitle = NSTextField(labelWithString: "API")
        apiTitle.font = NSFont.boldSystemFont(ofSize: 13)
        apiTitle.frame = NSRect(x: 20, y: y, width: 420, height: 20)
        contentView.addSubview(apiTitle)
        y -= 26

        let apiDesc = NSTextField(labelWithString: "Required for the native form. Generate a bearer token from\nyour scrt.link account.")
        apiDesc.font = NSFont.systemFont(ofSize: 11)
        apiDesc.textColor = .secondaryLabelColor
        apiDesc.maximumNumberOfLines = 2
        apiDesc.frame = NSRect(x: 20, y: y - 4, width: 420, height: 30)
        contentView.addSubview(apiDesc)
        y -= 36

        let tokenLabel = NSTextField(labelWithString: "Token:")
        tokenLabel.font = NSFont.systemFont(ofSize: 12)
        tokenLabel.frame = NSRect(x: 20, y: y + 2, width: 60, height: 18)
        contentView.addSubview(tokenLabel)

        apiTokenField = NSSecureTextField()
        apiTokenField.placeholderString = "Bearer token"
        apiTokenField.stringValue = KeychainStore.apiToken
        apiTokenField.frame = NSRect(x: 85, y: y, width: 270, height: 24)
        contentView.addSubview(apiTokenField)

        let saveTokenButton = NSButton(title: "Save", target: self, action: #selector(saveToken))
        saveTokenButton.bezelStyle = .rounded
        saveTokenButton.frame = NSRect(x: 362, y: y - 2, width: 70, height: 28)
        contentView.addSubview(saveTokenButton)
        y -= 34

        useWebUICheckbox = NSButton(checkboxWithTitle: "Use Web UI instead of native form",
                                    target: self, action: #selector(useWebUIToggleChanged))
        useWebUICheckbox.state = Preferences.useWebUI ? .on : .off
        useWebUICheckbox.frame = NSRect(x: 20, y: y, width: 420, height: 24)
        contentView.addSubview(useWebUICheckbox)
        y -= 22

        let webUIDescription = NSTextField(labelWithString: "When enabled, shows scrt.link embedded in a WebView instead\nof the native form. Useful for file secrets (not supported by API).")
        webUIDescription.font = NSFont.systemFont(ofSize: 11)
        webUIDescription.textColor = .secondaryLabelColor
        webUIDescription.maximumNumberOfLines = 2
        webUIDescription.frame = NSRect(x: 20, y: y - 4, width: 420, height: 30)
        contentView.addSubview(webUIDescription)
        y -= 34

        // Custom domain (white-label)
        let hostLabel = NSTextField(labelWithString: "Domain:")
        hostLabel.font = NSFont.systemFont(ofSize: 12)
        hostLabel.frame = NSRect(x: 20, y: y + 2, width: 60, height: 18)
        contentView.addSubview(hostLabel)

        customHostField = NSTextField()
        customHostField.placeholderString = "secrets.yourdomain.com (optional)"
        customHostField.stringValue = Preferences.customHost
        customHostField.frame = NSRect(x: 85, y: y, width: 270, height: 24)
        contentView.addSubview(customHostField)

        let saveHostButton = NSButton(title: "Save", target: self, action: #selector(saveCustomHost))
        saveHostButton.bezelStyle = .rounded
        saveHostButton.frame = NSRect(x: 362, y: y - 2, width: 70, height: 28)
        contentView.addSubview(saveHostButton)
        y -= 24

        let hostDesc = NSTextField(labelWithString: "White-label domain for created links. Requires scrt.link's\nSecret Service tier with the domain configured on their side.")
        hostDesc.font = NSFont.systemFont(ofSize: 11)
        hostDesc.textColor = .secondaryLabelColor
        hostDesc.maximumNumberOfLines = 2
        hostDesc.frame = NSRect(x: 20, y: y - 4, width: 420, height: 30)
        contentView.addSubview(hostDesc)
        y -= 30

        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.frame = NSRect(x: 20, y: y, width: 420, height: 1)
        contentView.addSubview(sep2)
        y -= 20

        // ========== DATA ==========
        let clearButton = NSButton(title: "Clear Website Data", target: self, action: #selector(clearData))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 20, y: y, width: 160, height: 28)
        contentView.addSubview(clearButton)
        y -= 22

        let clearDescription = NSTextField(labelWithString: "Clears cookies and cache for the embedded web view.")
        clearDescription.font = NSFont.systemFont(ofSize: 11)
        clearDescription.textColor = .secondaryLabelColor
        clearDescription.frame = NSRect(x: 20, y: y, width: 420, height: 18)
        contentView.addSubview(clearDescription)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let versionLabel = NSTextField(labelWithString: "Scrt.link v\(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.frame = NSRect(x: 20, y: 28, width: 420, height: 18)
        contentView.addSubview(versionLabel)

        let authorButton = NSButton(title: "Built by Mike Zielonka", target: self, action: #selector(openAuthorSite))
        authorButton.bezelStyle = .accessoryBarAction
        authorButton.isBordered = false
        authorButton.attributedTitle = NSAttributedString(
            string: "Built by Mike Zielonka · mikezielonka.com",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        authorButton.frame = NSRect(x: 20, y: 10, width: 420, height: 16)
        contentView.addSubview(authorButton)

        window.contentView = contentView
    }

    func showWindow() {
        dockCheckbox.state = DockManager.isShowingInDock ? .on : .off
        loginCheckbox.state = isLaunchAtLoginEnabled() ? .on : .off
        useWebUICheckbox.state = Preferences.useWebUI ? .on : .off
        apiTokenField.stringValue = KeychainStore.apiToken
        customHostField.stringValue = Preferences.customHost
        shortcutRecorder.shortcut = Preferences.shortcut
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

    // MARK: - Use Web UI

    @objc private func useWebUIToggleChanged() {
        Preferences.useWebUI = useWebUICheckbox.state == .on
        webViewController?.refreshMode()
    }

    // MARK: - API token

    @objc private func saveToken() {
        let token = apiTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.apiToken = token

        let alert = NSAlert()
        alert.messageText = token.isEmpty ? "Token Cleared" : "Token Saved"
        alert.informativeText = token.isEmpty
            ? "The API token has been removed."
            : "The API token has been saved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Custom host

    @objc private func saveCustomHost() {
        let host = customHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Basic sanitization — users might paste "https://..."; strip it.
        let cleaned = host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Preferences.customHost = cleaned
        customHostField.stringValue = cleaned

        let alert = NSAlert()
        alert.messageText = cleaned.isEmpty ? "Custom Domain Cleared" : "Custom Domain Saved"
        alert.informativeText = cleaned.isEmpty
            ? "New secrets will use scrt.link."
            : "New secrets will resolve to \(cleaned). Verify on scrt.link that this domain is configured for your account — otherwise the API call will fail."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Author site

    @objc private func openAuthorSite() {
        if let url = URL(string: "https://mikezielonka.com") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Clear Data

    @objc private func clearData() {
        let alert = NSAlert()
        alert.messageText = "Clear Website Data?"
        alert.informativeText = "This clears cookies and cached data used by the embedded web view. Your API token is not affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            webViewController?.clearWebsiteData()
        }
    }
}
