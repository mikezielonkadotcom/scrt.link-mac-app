import AppKit
import WebKit

var globalStatusBarController: StatusBarController?
var globalWebViewController: WebViewController?

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        globalWebViewController = WebViewController()
        globalStatusBarController = StatusBarController(webViewController: globalWebViewController!)

        DockManager.apply()

        globalWebViewController?.showWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { @MainActor in
            UpdateManager.shared.checkForUpdatesInBackground()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        globalWebViewController?.showWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Scrt.link", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = appMenu.addItem(withTitle: "Hide Scrt.link", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        let showAllItem = appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Scrt.link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — important so Cmd+C/V/X work inside the WebView form
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Open Scrt.link", action: #selector(openDashboard), keyEquivalent: "o")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Run API Diagnostic", action: #selector(runDiagnostic), keyEquivalent: "d")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func openPreferences() {
        globalStatusBarController?.openPreferencesFromMenu()
    }

    @objc func checkForUpdates() {
        UpdateManager.shared.checkForUpdatesInteractive()
    }

    @objc func openDashboard() {
        globalWebViewController?.showWindow()
    }

    @objc func reloadPage() {
        globalWebViewController?.reload()
    }

    @objc func runDiagnostic() {
        ScrtLinkAPI.shared.runDiagnostic { report in
            let alert = NSAlert()
            alert.messageText = "API Diagnostic"
            alert.informativeText = report
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(report, forType: .string)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
