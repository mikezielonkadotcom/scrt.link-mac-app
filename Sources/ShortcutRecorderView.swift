import AppKit
import Carbon.HIToolbox

/// A compact Mac-style shortcut recorder. Click to enter recording mode,
/// press any modifier+key combo to capture it, Esc to cancel. The Clear
/// button disables the shortcut; Reset restores the default.
@MainActor
final class ShortcutRecorderView: NSView {

    /// Current shortcut. `nil` = disabled (no hotkey registered).
    var shortcut: ShortcutSpec? {
        didSet {
            updateDisplay()
            if shortcut != oldValue { onChange?(shortcut) }
        }
    }

    /// Called whenever the user finishes editing — the new value is passed
    /// in. `nil` means "disabled by user".
    var onChange: ((ShortcutSpec?) -> Void)?

    private let recordButton = NSButton()
    private let clearButton = NSButton()
    private let resetButton = NSButton()
    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
        updateDisplay()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Monitor teardown is handled by stopRecording(); we don't need a
    // deinit cleanup since this view's lifetime is bounded by the
    // Preferences window's lifetime.

    private func setup() {
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.title = "Disable"
        clearButton.target = self
        clearButton.action = #selector(disableShortcut)

        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.title = "Reset"
        resetButton.target = self
        resetButton.action = #selector(resetShortcut)

        let stack = NSStackView(views: [recordButton, clearButton, resetButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateDisplay() {
        if isRecording {
            recordButton.title = "Press a shortcut…"
        } else if let s = shortcut {
            recordButton.title = s.displayString
        } else {
            recordButton.title = "Click to set"
        }
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    @objc private func disableShortcut() {
        stopRecording()
        shortcut = nil
    }

    @objc private func resetShortcut() {
        stopRecording()
        shortcut = Preferences.defaultShortcut
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        updateDisplay()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.handleKey(event: event) {
                return nil  // swallow — consumed
            }
            return event
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        updateDisplay()
    }

    /// Returns true if the event was consumed (recording finished or cancelled).
    private func handleKey(event: NSEvent) -> Bool {
        let keyCode = UInt32(event.keyCode)

        // Esc cancels without changing the stored shortcut
        if Int(keyCode) == kVK_Escape {
            stopRecording()
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = carbonModifiers(from: modifiers)
        // Require at least one modifier so we don't trap bare keys
        guard carbon != 0 else { return false }

        shortcut = ShortcutSpec(keyCode: keyCode, carbonModifiers: carbon)
        stopRecording()
        return true
    }

    private func carbonModifiers(from ns: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if ns.contains(.command) { m |= UInt32(cmdKey) }
        if ns.contains(.shift)   { m |= UInt32(shiftKey) }
        if ns.contains(.option)  { m |= UInt32(optionKey) }
        if ns.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
