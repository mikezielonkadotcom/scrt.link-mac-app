import AppKit

/// Handles the macOS Services menu entry "Create Scrt.link Secret". Users
/// right-click selected text in any app → Services → Create Scrt.link Secret
/// and we open the compose window prefilled with that text.
///
/// Declared in Info.plist under NSServices with NSMessage="createScrtLinkSecret".
@MainActor
final class ServiceProvider: NSObject {

    @objc func createScrtLinkSecret(_ pasteboard: NSPasteboard,
                                    userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pasteboard.string(forType: .string) ?? ""
        globalWebViewController?.showAndCompose(prefill: text)
    }
}
