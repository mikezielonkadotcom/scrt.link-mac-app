import AppKit

/// Central place for scrt.link brand colors and reusable button styling.
@MainActor
enum BrandStyle {
    /// scrt.link hot pink (#ff0083)
    static let accent = NSColor(red: 1.0, green: 0.0, blue: 0.513, alpha: 1.0)

    /// Soft gray canvas behind the elevated form card. Adapts to light/dark.
    static let surface = NSColor(name: NSColor.Name("scrtSurface")) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0.105, green: 0.105, blue: 0.118, alpha: 1)
            : NSColor(red: 0.945, green: 0.945, blue: 0.957, alpha: 1)
    }

    /// Elevated surface (the white card). Slightly lighter than `surface`.
    static let elevatedSurface = NSColor(name: NSColor.Name("scrtElevated")) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0.160, green: 0.160, blue: 0.176, alpha: 1)
            : NSColor.white
    }

    /// Style a button as the primary pink action.
    static func applyPrimary(_ button: NSButton) {
        button.bezelStyle = .rounded
        if #available(macOS 11.0, *) {
            button.bezelColor = accent
            button.contentTintColor = .white
        }
        // Make the title bolder
        let title = button.title
        let attr = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        button.attributedTitle = attr
    }

    /// Style a button as a compact secondary (used for Copy / Open in rows).
    static func applySecondary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .small
    }
}
