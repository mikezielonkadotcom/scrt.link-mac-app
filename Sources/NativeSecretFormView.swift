import AppKit

@MainActor
final class NativeSecretFormView: NSView {

    private struct TypeOption { let label: String; let value: String }
    private let types: [TypeOption] = [
        TypeOption(label: "Text",                 value: "text"),
        TypeOption(label: "Redirect URL",         value: "redirect"),
        TypeOption(label: "Neogram (auto-burn)",  value: "neogram"),
    ]

    private struct ExpOption { let label: String; let ms: Int }
    private let expirations: [ExpOption] = [
        ExpOption(label: "10 minutes", ms: 10 * 60 * 1000),
        ExpOption(label: "1 hour",     ms: 60 * 60 * 1000),
        ExpOption(label: "24 hours",   ms: 24 * 60 * 60 * 1000),
        ExpOption(label: "7 days",     ms: 7 * 24 * 60 * 60 * 1000),
        ExpOption(label: "30 days",    ms: 30 * 24 * 60 * 60 * 1000),
    ]

    private let card = ElevatedCard()
    private let typePopup = NSPopUpButton()
    private let expPopup = NSPopUpButton()
    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let passwordField = NSSecureTextField()
    private let noteField = NSTextField()
    private let createButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultCard = ResultCardView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = BrandStyle.surface.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setup() {
        autoresizingMask = [.width]

        // Elevated white card holds all form content
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28),
        ])

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 32, left: 36, bottom: 32, right: 36)
        root.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: card.topAnchor),
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // Display-size title
        let title = NSTextField(labelWithString: "New Secret")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Encrypted on your device. Viewable only once.")
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        root.setCustomSpacing(22, after: subtitle)

        root.addArrangedSubview(sectionLabel("TYPE"))
        typePopup.addItems(withTitles: types.map { $0.label })
        typePopup.translatesAutoresizingMaskIntoConstraints = false
        typePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        root.addArrangedSubview(typePopup)

        root.addArrangedSubview(sectionLabel("SECRET"))
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        textScroll.autohidesScrollers = true
        textScroll.borderType = .lineBorder
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 8
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        textScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textScroll.documentView = textView
        root.addArrangedSubview(textScroll)
        textScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -72).isActive = true

        root.addArrangedSubview(sectionLabel("EXPIRES IN"))
        expPopup.addItems(withTitles: expirations.map { $0.label })
        expPopup.selectItem(at: 2)
        expPopup.translatesAutoresizingMaskIntoConstraints = false
        expPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        root.addArrangedSubview(expPopup)

        root.addArrangedSubview(sectionLabel("OPTIONS"))

        passwordField.placeholderString = "Optional password"
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        root.addArrangedSubview(passwordField)

        noteField.placeholderString = "Optional public note — also used as the history label"
        noteField.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(noteField)
        noteField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -72).isActive = true

        root.setCustomSpacing(22, after: noteField)

        createButton.title = "Create Secret"
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createTapped)
        BrandStyle.applyPrimary(createButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = .secondaryLabelColor

        let actionRow = NSStackView(views: [createButton, spinner, statusLabel])
        actionRow.orientation = .horizontal
        actionRow.spacing = 12
        actionRow.alignment = .centerY
        root.addArrangedSubview(actionRow)

        resultCard.isHidden = true
        resultCard.onCopy = { [weak self] link in
            self?.copyToClipboard(link)
            self?.flashStatus("Copied.", isError: false)
        }
        resultCard.onOpen = { link in
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(resultCard)
        resultCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -72).isActive = true
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        return l
    }

    @objc private func createTapped() {
        let rawText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            flashStatus("Secret can't be empty.", isError: true)
            return
        }

        let type = types[typePopup.indexOfSelectedItem].value
        let expMs = expirations[expPopup.indexOfSelectedItem].ms
        let password = passwordField.stringValue
        let note = noteField.stringValue

        setBusy(true)
        statusLabel.stringValue = "Encrypting and uploading…"
        statusLabel.textColor = .secondaryLabelColor
        resultCard.isHidden = true

        ScrtLinkAPI.shared.createSecret(
            text: rawText,
            secretType: type,
            expiresInMs: expMs,
            password: password,
            publicNote: note
        ) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .success(let r):
                self.resultCard.show(link: r.secretLink)
                self.statusLabel.stringValue = "Link copied to clipboard"
                self.statusLabel.textColor = .secondaryLabelColor
                self.copyToClipboard(r.secretLink)
                let entry = SecretEntry(
                    expiresAt: Self.parseDate(r.expiresAt),
                    link: r.secretLink,
                    receiptId: r.receiptId,
                    secretType: type,
                    publicNote: note.isEmpty ? nil : note
                )
                SecretHistoryStore.add(entry)
                self.clearInputFields()
            case .failure(let err):
                self.flashStatus(err.localizedDescription, isError: true)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        createButton.isEnabled = !busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func flashStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func clearInputFields() {
        textView.string = ""
        passwordField.stringValue = ""
        noteField.stringValue = ""
    }

    func reset() {
        clearInputFields()
        resultCard.isHidden = true
        statusLabel.stringValue = ""
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        if let d = iso8601.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Elevated card (the white surface with a subtle drop shadow)

@MainActor
final class ElevatedCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Don't clip the shadow to view bounds
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 14
        layer?.backgroundColor = BrandStyle.elevatedSurface.cgColor
        // No border — just a whisper of shadow for depth
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.05
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8
        layer?.masksToBounds = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Result card

@MainActor
private final class ResultCardView: NSView {
    var onCopy: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    private let checkmark = NSImageView()
    private let heading = NSTextField(labelWithString: "Secret created")
    private let linkField = NSTextField()
    private let copyButton = NSButton()
    private let openButton = NSButton()

    private var currentLink: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = 10
        // Subtle pink-tinted success background
        layer?.backgroundColor = BrandStyle.accent.withAlphaComponent(0.08).cgColor
        layer?.borderColor = BrandStyle.accent.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 0.5
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setup() {
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                  accessibilityDescription: "Success")
        checkmark.contentTintColor = BrandStyle.accent
        checkmark.imageScaling = .scaleProportionallyUpOrDown
        checkmark.translatesAutoresizingMaskIntoConstraints = false

        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let topRow = NSStackView(views: [checkmark, heading])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.translatesAutoresizingMaskIntoConstraints = false

        linkField.isEditable = false
        linkField.isSelectable = true
        linkField.isBordered = false
        linkField.drawsBackground = false
        linkField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.maximumNumberOfLines = 1
        linkField.translatesAutoresizingMaskIntoConstraints = false

        copyButton.title = "Copy"
        BrandStyle.applyPrimary(copyButton)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        openButton.title = "Open"
        BrandStyle.applySecondary(openButton)
        openButton.target = self
        openButton.action = #selector(openTapped)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [copyButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topRow)
        addSubview(linkField)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            checkmark.widthAnchor.constraint(equalToConstant: 18),
            checkmark.heightAnchor.constraint(equalToConstant: 18),

            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            linkField.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            linkField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            linkField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: linkField.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    func show(link: String) {
        currentLink = link
        linkField.stringValue = link
        isHidden = false
    }

    @objc private func copyTapped() { onCopy?(currentLink) }
    @objc private func openTapped() { onOpen?(currentLink) }
}
