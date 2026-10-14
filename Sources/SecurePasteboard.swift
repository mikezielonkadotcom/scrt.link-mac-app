import AppKit

/// The one place the app writes secret links to the clipboard.
///
/// A scrt.link link carries its decryption key in the `#` fragment, so every
/// copy is a credential copy. Alongside the plain string this helper declares
/// `org.nspasteboard.ConcealedType`, the de facto marker password managers use
/// (see nspasteboard.org) so compliant clipboard managers such as Paste, Maccy,
/// Alfred and Raycast skip the entry instead of persisting it in their history.
enum SecurePasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Replaces the pasteboard contents with `text`, marked as concealed.
    /// Returns false if the string could not be written.
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: concealedType)
        return wrote
    }
}
