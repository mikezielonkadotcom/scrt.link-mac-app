import Foundation
import Carbon.HIToolbox

/// A keyboard shortcut in terms Carbon's RegisterEventHotKey understands.
/// Persisted to UserDefaults via JSON.
struct ShortcutSpec: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    /// Display string using standard Apple glyphs (⌘⇧⌥⌃) plus the key name.
    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(ShortcutSpec.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        default: return "key(\(code))"
        }
    }
}

enum Preferences {
    private static let useWebUIKey = "useWebUI"
    private static let customHostKey = "scrtLinkCustomHost"

    /// When false (default), the main window shows the native AppKit form that
    /// calls scrt.link's API via their client module. When true, the window
    /// embeds the scrt.link site directly in a WKWebView.
    static var useWebUI: Bool {
        get { UserDefaults.standard.bool(forKey: useWebUIKey) }
        set { UserDefaults.standard.set(newValue, forKey: useWebUIKey) }
    }

    /// Optional custom domain for white-labeled secret links. When set to
    /// e.g. "secrets.yourdomain.com", created links resolve to that domain
    /// instead of scrt.link. Requires scrt.link's Secret Service tier and a
    /// domain configured on their side — wrong-value in this field will
    /// cause the API call to fail at the host.
    static var customHost: String {
        get { UserDefaults.standard.string(forKey: customHostKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: customHostKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: customHostKey)
            }
        }
    }

    // MARK: - Global hotkey

    static let defaultShortcut = ShortcutSpec(
        keyCode: UInt32(kVK_ANSI_S),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )
    private static let shortcutDataKey = "scrtLinkShortcut"
    private static let shortcutConfiguredKey = "scrtLinkShortcutConfigured"

    /// User's chosen global hotkey.
    /// `nil` means the user explicitly disabled the hotkey.
    /// If never configured, returns `defaultShortcut`.
    static var shortcut: ShortcutSpec? {
        get {
            let configured = UserDefaults.standard.bool(forKey: shortcutConfiguredKey)
            if !configured { return defaultShortcut }
            guard let data = UserDefaults.standard.data(forKey: shortcutDataKey) else {
                return nil  // explicitly disabled
            }
            return try? JSONDecoder().decode(ShortcutSpec.self, from: data)
        }
        set {
            UserDefaults.standard.set(true, forKey: shortcutConfiguredKey)
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: shortcutDataKey)
            } else {
                UserDefaults.standard.removeObject(forKey: shortcutDataKey)
            }
            NotificationCenter.default.post(name: .shortcutChanged, object: nil)
        }
    }

    /// Forget the user's choice so the getter returns the default again.
    static func resetShortcutToDefault() {
        UserDefaults.standard.removeObject(forKey: shortcutDataKey)
        UserDefaults.standard.removeObject(forKey: shortcutConfiguredKey)
        NotificationCenter.default.post(name: .shortcutChanged, object: nil)
    }
}

extension Notification.Name {
    static let shortcutChanged = Notification.Name("scrtLinkShortcutChanged")
}
