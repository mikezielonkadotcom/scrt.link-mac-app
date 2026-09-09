import AppKit

@MainActor
final class HistorySidebarView: NSView {

    private let visualEffect = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "RECENT · LAST 24 HOURS")
    private let emptyLabel = NSTextField(labelWithString: "No secrets in the last 24 hours.\nNew links land here; older ones stay in the full log.")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let clearButton = NSButton()
    private let logButton = NSButton()
    /// Re-renders relative timestamps and drops entries that have aged past
    /// the 24-hour window. Runs only while the view is in a window.
    private var refreshTimer: Timer?
    private let accountStatusDot = StatusDot()
    private let accountLink = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onHistoryChanged),
            name: .secretHistoryChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAccountStatus),
            name: .apiTokenChanged, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The main window is never released or emptied on close — it's just
    /// ordered out — so "in a window" is not the same as "visible". Drive the
    /// timer from the window's close/occlusion notifications instead, the
    /// same way SecretLogWindow does, so a menu-bar-resident app isn't
    /// rebuilding an invisible list once a minute for days.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)

        guard let window else { stopRefreshTimer(); return }
        nc.addObserver(self, selector: #selector(onWindowVisibilityChanged(_:)),
                       name: NSWindow.willCloseNotification, object: window)
        nc.addObserver(self, selector: #selector(onWindowVisibilityChanged(_:)),
                       name: NSWindow.didChangeOcclusionStateNotification, object: window)
        syncTimerToVisibility(closing: false)
    }

    @objc private func onWindowVisibilityChanged(_ note: Notification) {
        syncTimerToVisibility(closing: note.name == NSWindow.willCloseNotification)
    }

    private func syncTimerToVisibility(closing: Bool) {
        // willClose fires before occlusionState updates, so treat it as hidden.
        if !closing, window?.occlusionState.contains(.visible) == true {
            startRefreshTimer()
            reload()  // catch up on anything that aged out while hidden
        } else {
            stopRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        // Once a minute is enough: relative times only change per minute and
        // the 24 h cutoff moving by 60 s is invisible to the user.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(onRefreshTick), userInfo: nil, repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func onRefreshTick() { reload() }

    // MARK: - Setup

    private func setup() {
        // Native macOS sidebar vibrancy — matches Finder/Mail/Messages.
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .followsWindowActiveState
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffect)
        NSLayoutConstraint.activate([
            visualEffect.topAnchor.constraint(equalTo: topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Logo + wordmark header
        let logoBar = NSStackView()
        logoBar.orientation = .horizontal
        logoBar.spacing = 10
        logoBar.alignment = .centerY
        logoBar.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 10, right: 18)

        let logo = NSImageView()
        logo.image = NSImage(named: NSImage.Name("NSApplicationIcon"))
        logo.imageScaling = .scaleProportionallyDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 26).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let wordmark = NSTextField(labelWithString: "Scrt.link")
        wordmark.font = .systemFont(ofSize: 14, weight: .semibold)

        logoBar.addArrangedSubview(logo)
        logoBar.addArrangedSubview(wordmark)
        logoBar.addArrangedSubview(NSView())

        // Section header
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 6, right: 18)
        headerRow.addArrangedSubview(header)
        headerRow.addArrangedSubview(NSView())

        // Scrollable list of cards
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 16, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // AppKit's default clip view is NOT flipped: a document shorter than
        // the viewport sits at the *bottom*, and a taller one opens scrolled
        // to the bottom. Either way the newest card (index 0) ended up out of
        // sight. A flipped clip view anchors y=0 to the top like every other
        // list on the platform.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        // Empty state
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        // Footer actions: full log (everything retained) + clear (wipes all)
        logButton.title = "View Full Log…"
        logButton.bezelStyle = .rounded
        logButton.controlSize = .small
        logButton.target = self
        logButton.action = #selector(logTapped)
        logButton.toolTip = "Every link this app has created, not just the last 24 hours"

        clearButton.title = "Clear History"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.toolTip = "Delete all local history (recent and full log)"
        clearButton.isHidden = true

        let actionRow = NSStackView(views: [logButton, clearButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 6
        actionRow.alignment = .centerY

        // Account status row: colored dot + state-aware link
        accountStatusDot.translatesAutoresizingMaskIntoConstraints = false
        accountStatusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        accountStatusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        accountLink.bezelStyle = .accessoryBarAction
        accountLink.controlSize = .small
        accountLink.isBordered = false
        accountLink.target = self
        accountLink.action = #selector(accountLinkTapped)

        let accountRow = NSStackView(views: [accountStatusDot, accountLink])
        accountRow.orientation = .horizontal
        accountRow.spacing = 6
        accountRow.alignment = .centerY

        // Attribution
        let attribution = NSTextField(labelWithString: "Unofficial client · Not affiliated with scrt.link")
        attribution.font = .systemFont(ofSize: 10)
        attribution.textColor = .tertiaryLabelColor
        attribution.alignment = .center

        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .centerX
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        footer.addArrangedSubview(actionRow)
        footer.addArrangedSubview(accountRow)
        footer.addArrangedSubview(attribution)

        refreshAccountStatus()

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(logoBar)
        root.addArrangedSubview(separator())
        root.addArrangedSubview(headerRow)
        root.addArrangedSubview(scrollView)
        root.addArrangedSubview(footer)

        visualEffect.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            root.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            logoBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            headerRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - Reload

    @objc private func onHistoryChanged() { reload() }

    /// Re-renders the list. One decode of the store serves both the recent
    /// filter and the "is there anything at all" check. When the set of
    /// visible entries hasn't changed (the usual case for the minute timer)
    /// only the relative timestamps are refreshed in place — no card churn
    /// and, importantly, no scroll reset under the user's cursor.
    func reload() {
        let now = Date()
        let all = SecretHistoryStore.load()  // newest first
        let cutoff = now.addingTimeInterval(-SecretHistoryStore.recentWindow)
        let entries = all.filter { $0.createdAt > cutoff }

        clearButton.isHidden = all.isEmpty
        emptyLabel.isHidden = !entries.isEmpty

        let existing = stack.arrangedSubviews.compactMap { $0 as? HistoryCardView }
        if existing.map(\.entry.id) == entries.map(\.id) {
            existing.forEach { $0.refresh(now: now) }
            return
        }

        existing.forEach { $0.removeFromSuperview() }
        for entry in entries {
            let card = HistoryCardView(entry: entry, now: now)
            card.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(card)
            // Width constraint must come AFTER addArrangedSubview — otherwise
            // the card and the stack have no common ancestor and AppKit raises
            // an uncaught exception that takes down both the window and the
            // status bar item with it.
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }

        // The list changed (new secret, or one aged out): show the newest.
        stack.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Actions

    @objc private func refreshAccountStatus() {
        let connected = KeychainStore.hasToken
        accountStatusDot.color = connected
            ? NSColor.systemGreen
            : NSColor.tertiaryLabelColor
        let labelText = connected
            ? "Connected · View scrt.link account →"
            : "Not connected · Set API token"
        accountLink.attributedTitle = NSAttributedString(
            string: labelText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: connected ? BrandStyle.accent : NSColor.secondaryLabelColor,
            ]
        )
    }

    @objc private func accountLinkTapped() {
        if KeychainStore.hasToken {
            if let url = URL(string: "https://scrt.link/account") {
                NSWorkspace.shared.open(url)
            }
        } else {
            // No token yet — open Preferences so they can set one
            (NSApp.delegate as? AppDelegate)?.openPreferences()
        }
    }

    @objc private func logTapped() {
        (NSApp.delegate as? AppDelegate)?.openSecretLog()
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "Removes every local record of secrets you've created — the recent list and the full log. The secrets on scrt.link itself are unaffected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            SecretHistoryStore.clear()
        }
    }
}

// MARK: - Flipped clip view

/// Top-anchored scrolling. See the comment in `HistorySidebarView.setup()`.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Status dot

@MainActor
private final class StatusDot: NSView {
    var color: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = (layer?.bounds.width ?? 8) / 2
        layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Card

@MainActor
private final class HistoryCardView: NSView {
    let entry: SecretEntry
    private var now: Date
    private let sub = NSTextField(labelWithString: "")
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(entry: SecretEntry, now: Date = Date()) {
        self.entry = entry
        self.now = now
        super.init(frame: .zero)
        wantsLayer = true
        // Draw on every appearance change so our colors stay in sync.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Re-apply layer colors when the system switches between light/dark.
    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setup() {
        let title = NSTextField(labelWithString: labelText())
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false

        sub.stringValue = subtitleText()
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.translatesAutoresizingMaskIntoConstraints = false

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        BrandStyle.applySecondary(copyButton)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open", target: self, action: #selector(openTapped))
        BrandStyle.applySecondary(openButton)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [copyButton, openButton])
        actions.orientation = .horizontal
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(sub)
        addSubview(actions)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            actions.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 8),
            actions.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        heightAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
    }

    /// Re-render the relative timestamps against a new "now" without
    /// rebuilding the card.
    func refresh(now: Date) {
        self.now = now
        sub.stringValue = subtitleText()
    }

    private func labelText() -> String {
        entry.displayLabel
    }

    private func subtitleText() -> String {
        let f = Self.relativeFormatter
        let ago = f.localizedString(for: entry.createdAt, relativeTo: now)
        var parts = [SecretEntry.typeName(entry.secretType), ago]
        if let exp = entry.expiresAt {
            if exp > now {
                parts.append("expires " + f.localizedString(for: exp, relativeTo: now))
            } else {
                parts.append("expired")
            }
        }
        return parts.joined(separator: " · ")
    }

    @objc private func copyTapped() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.link, forType: .string)
    }

    @objc private func openTapped() {
        if let url = URL(string: entry.link) {
            NSWorkspace.shared.open(url)
        }
    }
}
