import AppKit

@MainActor
final class NativeSecretFormView: NSView {

    // Supported API secret types (file + snap are web-UI only)
    private struct TypeOption { let label: String; let value: String }
    private let types: [TypeOption] = [
        TypeOption(label: "Text",                 value: "text"),
        TypeOption(label: "Redirect URL",         value: "redirect"),
        TypeOption(label: "Neogram (auto-burn)",  value: "neogram"),
    ]

    // TTL options match the scrt.link web UI
    private struct ExpOption { let label: String; let ms: Int }
    private let expirations: [ExpOption] = [
        ExpOption(label: "10 minutes", ms: 10 * 60 * 1000),
        ExpOption(label: "1 hour",     ms: 60 * 60 * 1000),
        ExpOption(label: "24 hours",   ms: 24 * 60 * 60 * 1000),
        ExpOption(label: "7 days",     ms: 7 * 24 * 60 * 60 * 1000),
        ExpOption(label: "30 days",    ms: 30 * 24 * 60 * 60 * 1000),
    ]

    private let typePopup = NSPopUpButton()
    private let expPopup = NSPopUpButton()
    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let passwordField = NSSecureTextField()
    private let notePopupField = NSTextField()
    private let createButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultBox = NSStackView()
    private let resultField = NSTextField()
    private let copyButton = NSButton()
    private let openButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        autoresizingMask = [.width, .height]
        wantsLayer = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Title
        let title = NSTextField(labelWithString: "New Secret")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Encrypted on your device, viewable only once.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        // Type row
        root.addArrangedSubview(labeledRow(
            label: "Type",
            control: typePopup,
            width: 240
        ))
        typePopup.addItems(withTitles: types.map { $0.label })

        // Text body
        let textLabel = NSTextField(labelWithString: "Secret")
        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        root.addArrangedSubview(textLabel)

        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        textScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textScroll.documentView = textView
        root.addArrangedSubview(textScroll)

        // Expiration row
        root.addArrangedSubview(labeledRow(
            label: "Expires in",
            control: expPopup,
            width: 180
        ))
        expPopup.addItems(withTitles: expirations.map { $0.label })
        expPopup.selectItem(at: 2) // 24 hours default

        // Password (optional)
        passwordField.placeholderString = "Optional password"
        root.addArrangedSubview(labeledRow(
            label: "Password",
            control: passwordField,
            width: 300
        ))

        // Public note (optional)
        notePopupField.placeholderString = "Optional note shown before opening"
        root.addArrangedSubview(labeledRow(
            label: "Public note",
            control: notePopupField,
            width: 420
        ))

        // Create button + spinner + status
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY

        createButton.title = "Create Secret"
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(createTapped)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        actionRow.addArrangedSubview(createButton)
        actionRow.addArrangedSubview(spinner)
        actionRow.addArrangedSubview(statusLabel)
        root.addArrangedSubview(actionRow)

        // Result row (hidden until we have a link)
        resultBox.orientation = .horizontal
        resultBox.spacing = 8
        resultBox.alignment = .centerY
        resultBox.isHidden = true

        resultField.isEditable = false
        resultField.isSelectable = true
        resultField.bezelStyle = .squareBezel
        resultField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        copyButton.title = "Copy"
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTapped)

        openButton.title = "Open"
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openTapped)

        resultBox.addArrangedSubview(resultField)
        resultBox.addArrangedSubview(copyButton)
        resultBox.addArrangedSubview(openButton)
        root.addArrangedSubview(resultBox)
    }

    private func labeledRow(label: String, control: NSView, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 90).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func createTapped() {
        let rawText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            flashStatus("Secret can't be empty.", isError: true)
            return
        }

        let type = types[typePopup.indexOfSelectedItem].value
        let expMs = expirations[expPopup.indexOfSelectedItem].ms
        let password = passwordField.stringValue
        let note = notePopupField.stringValue

        setBusy(true)
        statusLabel.stringValue = "Encrypting and uploading…"
        statusLabel.textColor = .secondaryLabelColor
        resultBox.isHidden = true

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
                self.showResult(link: r.secretLink)
                self.statusLabel.stringValue = "Secret created. Link copied to clipboard."
                self.statusLabel.textColor = .secondaryLabelColor
            case .failure(let err):
                self.flashStatus(err.localizedDescription, isError: true)
            }
        }
    }

    @objc private func copyTapped() {
        copyToClipboard(resultField.stringValue)
        flashStatus("Copied.", isError: false)
    }

    @objc private func openTapped() {
        if let url = URL(string: resultField.stringValue) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private func setBusy(_ busy: Bool) {
        createButton.isEnabled = !busy
        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showResult(link: String) {
        resultField.stringValue = link
        resultBox.isHidden = false
        copyToClipboard(link)
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

    /// Called by the window controller after the user clears the form so the
    /// view is ready for another secret.
    func reset() {
        textView.string = ""
        passwordField.stringValue = ""
        notePopupField.stringValue = ""
        resultBox.isHidden = true
        resultField.stringValue = ""
        statusLabel.stringValue = ""
    }
}
