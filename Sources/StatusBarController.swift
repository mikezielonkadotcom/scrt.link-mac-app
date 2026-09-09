import AppKit

@MainActor
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var webViewController: WebViewController
    private var preferencesWindow: PreferencesWindow?

    init(webViewController: WebViewController) {
        self.webViewController = webViewController
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        var imageLoaded = false
        if let resourcePath = Bundle.main.resourcePath {
            let icon2x = NSImage(contentsOfFile: "\(resourcePath)/StatusBarIcon@2x.png")
            let icon1x = NSImage(contentsOfFile: "\(resourcePath)/StatusBarIcon.png")
            if let image = icon2x ?? icon1x {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
                imageLoaded = true
            }
        }

        if !imageLoaded {
            // SF Symbol fallback — keeps it looking native without a bundled PNG
            if let symbol = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Scrt.link") {
                symbol.isTemplate = true
                button.image = symbol
            } else {
                button.title = "🔒"
            }
        }

        button.toolTip = "Scrt.link"

        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick(_:))
        button.target = self
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            webViewController.toggleWindow()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open Scrt.link", action: #selector(openDashboard), keyEquivalent: ""))
        menu.items.last?.target = self

        menu.addItem(NSMenuItem(title: "Secret Log...", action: #selector(openSecretLog), keyEquivalent: ""))
        menu.items.last?.target = self

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.items.last?.target = self

        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.items.last?.target = self

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit Scrt.link", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openDashboard() {
        webViewController.showWindow()
    }

    @objc private func openPreferences() {
        openPreferencesFromMenu()
    }

    @objc private func openSecretLog() {
        (NSApp.delegate as? AppDelegate)?.openSecretLog()
    }

    func openPreferencesFromMenu() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow(webViewController: webViewController)
        }
        preferencesWindow?.showWindow()
    }

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdatesInteractive()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
