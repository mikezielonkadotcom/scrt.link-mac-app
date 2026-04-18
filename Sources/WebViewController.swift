import AppKit
import WebKit

@MainActor
class WebViewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let homeURL = URL(string: "https://scrt.link/")!
    private var hasLoaded = false

    override init() {
        super.init()
        setupWebView()
        setupWindow()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        // Persistent store so paid-account cookies survive restarts
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    private func setupWindow() {
        let windowSize = NSSize(width: 900, height: 720)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Scrt.link"
        window.minSize = NSSize(width: 600, height: 500)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ScrtLinkMain")
        window.center()

        setupToolbar()
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    // MARK: - Window Management

    func showWindow() {
        if !hasLoaded {
            webView.load(URLRequest(url: homeURL))
            hasLoaded = true
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleWindow() {
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    func clearWebsiteData() {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) { @MainActor [weak self] in
            guard let self else { return }
            self.hasLoaded = false
            self.webView.load(URLRequest(url: self.homeURL))
        }
    }

    func reload() {
        webView.reload()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Keep scrt.link navigation inside the WebView.
        // A just-created secret link is ALSO scrt.link/s#... — we want to open
        // those externally so the user doesn't accidentally burn their own secret.
        if let host = url.host?.lowercased(), host.contains("scrt.link") {
            if navigationAction.navigationType == .linkActivated && url.path.hasPrefix("/s") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        } else if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - WKUIDelegate

    // target="_blank"
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn)
    }
}

// MARK: - NSToolbarDelegate

@MainActor
extension WebViewController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "BackForward":
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)

            let backItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Back"))
            backItem.label = "Back"
            backItem.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
            backItem.action = #selector(goBack)
            backItem.target = self

            let forwardItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("Forward"))
            forwardItem.label = "Forward"
            forwardItem.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
            forwardItem.action = #selector(goForward)
            forwardItem.target = self

            group.subitems = [backItem, forwardItem]
            group.label = "Navigation"
            return group

        case "Reload":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.action = #selector(doReload)
            item.target = self
            return item

        case "FlexibleSpace":
            return NSToolbarItem(itemIdentifier: .flexibleSpace)

        case "Home":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Home"
            item.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
            item.action = #selector(goHome)
            item.target = self
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            NSToolbarItem.Identifier("BackForward"),
            .flexibleSpace,
            NSToolbarItem.Identifier("Reload"),
            NSToolbarItem.Identifier("Home"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    @objc private func doReload() {
        reload()
    }

    @objc private func goHome() {
        webView.load(URLRequest(url: homeURL))
    }
}
