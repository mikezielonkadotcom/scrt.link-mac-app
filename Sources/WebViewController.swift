import AppKit
import WebKit

@MainActor
class WebViewController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var nativeForm: NativeSecretFormView?
    private var nativeContainer: NSView?  // split view with sidebar + form
    private var historySidebar: HistorySidebarView?
    private let homeURL = URL(string: "https://scrt.link/")!
    private var hasLoadedWeb = false
    private var currentMode: Mode = .native

    private enum Mode { case native, web }

    override init() {
        super.init()
        setupWebView()
        setupWindow()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.preferences.isElementFullscreenEnabled = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    private func setupWindow() {
        let windowSize = NSSize(width: 1060, height: 720)

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Scrt.link"
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ScrtLinkMain")
        window.center()

        setupToolbar()
        applyMode()
    }

    private func makeNativeContainer() -> NSView {
        let form = NativeSecretFormView(frame: .zero)
        let sidebar = HistorySidebarView(frame: .zero)
        self.nativeForm = form
        self.historySidebar = sidebar

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar wrapped in a scroll-safe container for consistent sizing
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let sidebarHolder = NSView()
        sidebarHolder.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: sidebarHolder.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: sidebarHolder.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarHolder.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: sidebarHolder.trailingAnchor),
        ])

        let formScroll = NSScrollView()
        formScroll.hasVerticalScroller = true
        formScroll.scrollerStyle = .overlay
        formScroll.autohidesScrollers = true
        formScroll.drawsBackground = true
        formScroll.backgroundColor = BrandStyle.surface
        formScroll.documentView = form
        // Stretch the form's width to match the clip view so the gray canvas
        // fills the whole right pane, and the card inside can size properly.
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            form.widthAnchor.constraint(equalTo: formScroll.contentView.widthAnchor),
            form.topAnchor.constraint(equalTo: formScroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: formScroll.contentView.leadingAnchor),
        ])

        split.addArrangedSubview(sidebarHolder)
        split.addArrangedSubview(formScroll)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

        // Initial sizing: sidebar ~280, form fills
        DispatchQueue.main.async { split.setPosition(280, ofDividerAt: 0) }

        return split
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    // MARK: - Mode switching

    private func applyMode() {
        let desired: Mode = Preferences.useWebUI ? .web : .native
        switch desired {
        case .native:
            if nativeContainer == nil {
                nativeContainer = makeNativeContainer()
            }
            window.contentView = nativeContainer
            window.title = "Scrt.link"
        case .web:
            if !hasLoadedWeb {
                webView.load(URLRequest(url: homeURL))
                hasLoadedWeb = true
            }
            window.contentView = webView
            window.title = "Scrt.link"
        }
        currentMode = desired
        // Rebuild toolbar items — native mode doesn't need nav controls
        window.toolbar?.delegate = self
        if let t = window.toolbar {
            // Force rebuild by re-assigning the identifier set
            while t.items.count > 0 {
                t.removeItem(at: 0)
            }
            for (i, id) in toolbarDefaultItemIdentifiers(t).enumerated() {
                t.insertItem(withItemIdentifier: id, at: i)
            }
        }
    }

    /// Called from Preferences when the "Use Web UI" toggle changes.
    func refreshMode() {
        applyMode()
    }

    // MARK: - Window Management

    func showWindow() {
        applyMode()
        ensureWindowOnScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Restore the user's preferred Dock visibility — closing the window
        // earlier would have demoted us to .accessory.
        DockManager.applyActivationPolicy(show: DockManager.isShowingInDock)
    }

    /// Recenter if the saved frame landed off-screen (e.g. monitor was
    /// disconnected since the last save).
    private func ensureWindowOnScreen() {
        guard let screens = NSScreen.screens as [NSScreen]? else { return }
        let frame = window.frame
        let intersectsAScreen = screens.contains { $0.visibleFrame.intersects(frame) }
        if !intersectsAScreen {
            window.center()
        }
    }

    /// Show the window (forcing native form mode) and prefill the secret
    /// text area with the given string. Called by the global hotkey and
    /// the Services menu integration.
    func showAndCompose(prefill: String) {
        // Force-switch to native form for compose — Web UI can't be prefilled.
        if Preferences.useWebUI {
            Preferences.useWebUI = false
        }
        applyMode()
        ensureWindowOnScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        nativeForm?.prefill(prefill)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // App lives in the menu bar by default. Closing the main window
        // demotes us to accessory mode so the Dock icon disappears; the
        // status bar icon remains responsive. Reopening (via menu bar
        // click, hotkey, services, etc.) restores Dock visibility per
        // the user's preference.
        DockManager.applyActivationPolicy(show: false)
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
            self.hasLoadedWeb = false
            if self.currentMode == .web {
                self.webView.load(URLRequest(url: self.homeURL))
            }
        }
    }

    func reload() {
        switch currentMode {
        case .native:
            nativeForm?.reset()
            historySidebar?.reload()
        case .web:
            webView.reload()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // A just-created secret link (scrt.link/s#...) should open in the
        // default browser so we don't accidentally burn it.
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
            item.label = currentMode == .native ? "New" : "Reload"
            item.image = NSImage(systemSymbolName: currentMode == .native ? "square.and.pencil" : "arrow.clockwise",
                                 accessibilityDescription: item.label)
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
        if currentMode == .native {
            return [
                .flexibleSpace,
                NSToolbarItem.Identifier("Reload"),
            ]
        }
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
        if currentMode == .web {
            webView.load(URLRequest(url: homeURL))
        }
    }
}
