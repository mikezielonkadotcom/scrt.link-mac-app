import AppKit

@MainActor
final class HistorySidebarView: NSView {

    private let visualEffect = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "RECENT")
    private let emptyLabel = NSTextField(labelWithString: "No secrets yet.\nCreated secrets land here for easy re-copy.")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let clearButton = NSButton()
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

    deinit { NotificationCenter.default.removeObserver(self) }

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
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        // Clear footer
        clearButton.title = "Clear History"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.isHidden = true

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
        footer.addArrangedSubview(clearButton)
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

    func reload() {
        let entries = SecretHistoryStore.load()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if entries.isEmpty {
            emptyLabel.isHidden = false
            clearButton.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        clearButton.isHidden = false

        for entry in entries {
            stack.addArrangedSubview(makeCard(for: entry))
        }
    }

    private func makeCard(for entry: SecretEntry) -> NSView {
        let card = HistoryCardView(entry: entry)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        return card
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

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "Removes local records of secrets you've created. The secrets on scrt.link itself are unaffected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            SecretHistoryStore.clear()
        }
    }
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
    private let entry: SecretEntry

    init(entry: SecretEntry) {
        self.entry = entry
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

        let sub = NSTextField(labelWithString: subtitleText())
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

    private func labelText() -> String {
        if let note = entry.publicNote, !note.isEmpty { return note }
        switch entry.secretType {
        case "redirect": return "Redirect"
        case "neogram":  return "Neogram"
        default:         return "Text secret"
        }
    }

    private func subtitleText() -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        let ago = f.localizedString(for: entry.createdAt, relativeTo: Date())
        var parts = [entry.secretType.capitalized, ago]
        if let exp = entry.expiresAt {
            if exp > Date() {
                parts.append("expires " + f.localizedString(for: exp, relativeTo: Date()))
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
