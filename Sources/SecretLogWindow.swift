import AppKit

/// The full history of links this app has created — everything the store
/// retains, not just the sidebar's 24-hour window. Newest first.
///
/// Links are bearer credentials (the URL fragment is the decryption key),
/// so the table deliberately never renders the URL itself. Copy / Open act
/// on the selection instead, same as the sidebar cards.
@MainActor
final class SecretLogWindow: NSObject {
    private var window: NSWindow!
    private let table = LogTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No secrets logged yet.")
    private let copyButton = NSButton(title: "Copy Link", target: nil, action: nil)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear Log…", target: nil, action: nil)

    private var allEntries: [SecretEntry] = []
    private var rows: [SecretEntry] = []
    private var refreshTimer: Timer?

    private let createdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    private enum Column: String, CaseIterable {
        case created, label, type, expires, receipt

        var title: String {
            switch self {
            case .created: return "Created"
            case .label:   return "Label"
            case .type:    return "Type"
            case .expires: return "Expires"
            case .receipt: return "Receipt"
            }
        }

        var width: (initial: CGFloat, min: CGFloat) {
            switch self {
            case .created: return (150, 120)
            case .label:   return (200, 100)
            case .type:    return (90, 70)
            case .expires: return (190, 100)
            case .receipt: return (110, 80)
            }
        }

        var identifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("log.\(rawValue)")
        }
    }

    override init() {
        super.init()
        setupWindow()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onHistoryChanged),
            name: .secretHistoryChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWindowClosed),
            name: NSWindow.willCloseNotification, object: window
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Secret Log"
        window.subtitle = "Every link created by this app"
        window.minSize = NSSize(width: 640, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ScrtLinkLog")
        window.center()

        // --- Top bar: search + count -------------------------------------
        searchField.placeholderString = "Filter by label, type, or receipt"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let topBar = NSStackView(views: [searchField, NSView(), countLabel])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 12
        topBar.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)

        // --- Table --------------------------------------------------------
        for column in Column.allCases {
            let col = NSTableColumn(identifier: column.identifier)
            col.title = column.title
            col.width = column.width.initial
            col.minWidth = column.width.min
            col.resizingMask = .userResizingMask
            table.addTableColumn(col)
        }
        if let labelCol = table.tableColumns.first(where: { $0.identifier == Column.label.identifier }) {
            labelCol.resizingMask = [.autoresizingMask, .userResizingMask]
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Track the clip view's width so the last column can absorb slack
        // instead of the table growing past the window edge.
        table.autoresizingMask = [.width]
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onDeleteKey = { [weak self] in self?.deleteTapped() }
        // Edit → Copy (⌘C) reaches the table through the responder chain, so
        // the search field keeps ⌘C for its own text while it has focus.
        table.onCopy = { [weak self] in self?.copyTapped() }
        table.menu = contextMenu()

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        // --- Bottom bar: selection actions + clear ------------------------
        for (button, action) in [
            (copyButton, #selector(copyTapped)),
            (openButton, #selector(openTapped)),
            (deleteButton, #selector(deleteTapped)),
            (clearButton, #selector(clearTapped)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        copyButton.toolTip = "Copy the selected link(s) to the clipboard (⌘C)"
        openButton.toolTip = "Open the selected link in your browser — this consumes the view"
        deleteButton.toolTip = "Remove the selected record(s) from this Mac. The secret on scrt.link is unaffected."
        clearButton.toolTip = "Delete every local record"

        let hint = NSTextField(labelWithString: "Links are bearer credentials — opening one uses up its view.")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor

        let bottomBar = NSStackView(views: [copyButton, openButton, deleteButton, hint, NSView(), clearButton])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 8
        bottomBar.setCustomSpacing(16, after: deleteButton)
        bottomBar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)

        // --- Root ---------------------------------------------------------
        let root = NSStackView(views: [topBar, separator(), scrollView, separator(), bottomBar])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            bottomBar.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        window.contentView = content

        updateSelectionButtons()
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    /// Context-menu items get their own selectors: a right-click does NOT
    /// move the selection, so they must act on `clickedRow`, not on whatever
    /// happened to be selected. The buttons and keyboard paths use the
    /// selection.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Link", action: #selector(contextCopy), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Browser", action: #selector(contextOpen), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "").target = self
        return menu
    }

    func showWindow() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshTimer()
    }

    // MARK: - Data

    @objc private func onHistoryChanged() { reload() }

    @objc private func onWindowClosed() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        // Keeps "Expires" / "Expired" honest while the window sits open.
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(onRefreshTick), userInfo: nil, repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @objc private func onRefreshTick() {
        table.reloadData()
    }

    private func reload() {
        allEntries = SecretHistoryStore.load()  // already newest first
        applyFilter()
    }

    private func applyFilter() {
        let selectedIds = Set(selectedEntries().map(\.id))
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            rows = allEntries
        } else {
            rows = allEntries.filter { entry in
                entry.displayLabel.lowercased().contains(query)
                    || entry.secretType.lowercased().contains(query)
                    || entry.receiptId.lowercased().contains(query)
            }
        }
        table.reloadData()

        // Preserve selection across reloads where possible.
        var reselect = IndexSet()
        for (i, entry) in rows.enumerated() where selectedIds.contains(entry.id) {
            reselect.insert(i)
        }
        table.selectRowIndexes(reselect, byExtendingSelection: false)

        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = allEntries.isEmpty
            ? "No secrets logged yet."
            : "No matches."
        clearButton.isEnabled = !allEntries.isEmpty

        let noun = allEntries.count == 1 ? "secret" : "secrets"
        countLabel.stringValue = query.isEmpty
            ? "\(allEntries.count) \(noun) · newest first"
            : "\(rows.count) of \(allEntries.count) \(noun)"
        updateSelectionButtons()
    }

    private func selectedEntries() -> [SecretEntry] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    /// Rows a click-driven action should target: the clicked row when it is
    /// outside the selection, otherwise the whole selection (right-clicking
    /// one of several selected rows acts on all of them, like Finder).
    /// `clickedRow` is only meaningful during a click-dispatched action.
    private func clickedEntries() -> [SecretEntry] {
        let clicked = table.clickedRow
        if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked) {
            return [rows[clicked]]
        }
        return selectedEntries()
    }

    private func updateSelectionButtons() {
        let count = table.selectedRowIndexes.count
        copyButton.isEnabled = count >= 1
        openButton.isEnabled = count == 1
        deleteButton.isEnabled = count >= 1
    }

    // MARK: - Actions

    @objc private func copyTapped() { copy(selectedEntries()) }
    @objc private func openTapped() { open(selectedEntries()) }
    @objc private func deleteTapped() { delete(selectedEntries()) }

    @objc private func contextCopy() { copy(clickedEntries()) }
    @objc private func contextOpen() { open(clickedEntries()) }
    @objc private func contextDelete() { delete(clickedEntries()) }

    @objc private func doubleClicked() {
        // Double-clicking the empty area below the rows is not a copy request.
        guard table.clickedRow >= 0 else { return }
        copy(clickedEntries())
    }

    private func copy(_ entries: [SecretEntry]) {
        let links = entries.map(\.link)
        guard !links.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(links.joined(separator: "\n"), forType: .string)
    }

    private func open(_ entries: [SecretEntry]) {
        guard let entry = entries.first, let url = URL(string: entry.link) else { return }
        NSWorkspace.shared.open(url)
    }

    private func delete(_ entries: [SecretEntry]) {
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return }
        SecretHistoryStore.remove(ids: Set(ids))
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "Clear the Secret Log?"
        alert.informativeText = "Removes every local record of secrets you've created (\(allEntries.count) total). The secrets on scrt.link itself are unaffected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                SecretHistoryStore.clear()
            }
        }
    }
}

// MARK: - Table data source / delegate

extension SecretLogWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count,
              let column = Column.allCases.first(where: { $0.identifier == tableColumn.identifier })
        else { return nil }

        let entry = rows[row]
        let now = Date()

        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = column.identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        guard let field = cell.textField else { return cell }
        field.font = .systemFont(ofSize: 12)
        field.textColor = entry.isExpired(at: now) ? .secondaryLabelColor : .labelColor
        field.toolTip = nil

        switch column {
        case .created:
            field.stringValue = createdFormatter.string(from: entry.createdAt)
        case .label:
            field.stringValue = entry.displayLabel
            field.font = .systemFont(ofSize: 12, weight: entry.publicNote == nil ? .regular : .medium)
            field.toolTip = entry.displayLabel
        case .type:
            field.stringValue = SecretEntry.typeName(entry.secretType)
        case .expires:
            if let exp = entry.expiresAt {
                if exp <= now {
                    field.stringValue = "Expired · " + createdFormatter.string(from: exp)
                } else {
                    field.stringValue = createdFormatter.string(from: exp)
                }
            } else {
                field.stringValue = "—"
            }
        case .receipt:
            field.stringValue = entry.receiptId
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.toolTip = entry.receiptId
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionButtons()
    }
}

// MARK: - Search

extension SecretLogWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

// MARK: - Table view with Delete-key and Edit → Copy support

@MainActor
private final class LogTableView: NSTableView, NSMenuItemValidation {
    var onDeleteKey: (() -> Void)?
    var onCopy: (() -> Void)?

    /// Responder-chain target for Edit → Copy (⌘C) while the table is first
    /// responder. Selector `copy:`, distinct from NSObject.copy().
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // 51 = Backspace, 117 = Forward Delete
        if event.keyCode == 51 || event.keyCode == 117, selectedRowIndexes.count > 0 {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }
}
