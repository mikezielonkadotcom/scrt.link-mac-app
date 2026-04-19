import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hot key via Carbon's Event Manager. Trigger fires
/// on the main thread. No Accessibility permission required.
///
/// The Carbon event handler is a C function pointer so it can't capture
/// Swift state — we route through a static dictionary keyed by hotkey id.
/// Access is serialized with an NSLock because the Carbon callback can fire
/// on any thread, though in practice Apple pumps it through the main event
/// loop.
final class GlobalHotKey {
    // These are accessed from the Carbon C callback which runs outside any
    // Swift actor — we serialize with `lock` ourselves.
    nonisolated(unsafe) fileprivate static var handlerInstalled = false
    fileprivate static let lock = NSLock()
    nonisolated(unsafe) fileprivate static var triggers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextId: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil if the OS rejects the registration (usually a conflict).
    init?(keyCode: UInt32, modifiers: UInt32, onTrigger: @escaping () -> Void) {
        Self.installHandlerIfNeeded()

        Self.lock.lock()
        self.id = Self.nextId
        Self.nextId += 1
        Self.triggers[self.id] = onTrigger
        Self.lock.unlock()

        let hotKeyID = EventHotKeyID(signature: 0x5343_5254 /* 'SCRT' */, id: self.id)
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &r)
        guard status == noErr, r != nil else {
            Self.lock.lock()
            Self.triggers.removeValue(forKey: self.id)
            Self.lock.unlock()
            return nil
        }
        self.ref = r
    }

    deinit {
        if let ref = ref { UnregisterEventHotKey(ref) }
        Self.lock.lock()
        Self.triggers.removeValue(forKey: id)
        Self.lock.unlock()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            scrtHotKeyEventHandler,
                            1, &eventType, nil, nil)
    }
}

// C-compatible top-level function used as the Carbon event callback.
private func scrtHotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return noErr }
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hkID)
    guard status == noErr else { return noErr }

    let id = hkID.id
    DispatchQueue.main.async {
        GlobalHotKey.lock.lock()
        let trigger = GlobalHotKey.triggers[id]
        GlobalHotKey.lock.unlock()
        trigger?()
    }
    return noErr
}
