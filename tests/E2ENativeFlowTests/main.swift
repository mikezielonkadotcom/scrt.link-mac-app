import AppKit
import Security
import WebKit

// In-process end-to-end test of the native secret flow, compiled by
// tests/test-e2e-native-flow.sh together with every app source except
// Sources/main.swift (this file supplies the globals and a stub AppDelegate).
//
// It builds the REAL WebViewController (main window, split view, sidebar and
// form) and the REAL SecretLogWindow, then drives them the way a user does:
// type a secret, pick options, click Create, and follow the link through the
// result card, the clipboard, the history store, the sidebar card and the
// Secret Log row. Error paths, the Services/hotkey prefill and the forced
// switch back to the native form are covered too.
//
// The only thing swapped is the scrt.link client-module import inside the
// real Resources/harness.html, replaced by an inline fake module that echoes
// the text and options it received into the link's fragment. Nothing touches
// the network, scrt.link, the app's Keychain item or the app's history.
//
// Switching INTO web mode is deliberately not exercised: that path loads
// https://scrt.link/ for real, and this suite stays offline.

// MARK: - Globals main.swift normally provides

var globalWebViewController: WebViewController?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesOpened = 0
    var secretLogOpened = 0
    @objc func openPreferences() { preferencesOpened += 1 }
    @objc func openSecretLog() { secretLogOpened += 1 }
}

// MARK: - Isolation

// The sidebar reads KeychainStore.hasToken. Point it at a throwaway service so
// this unsigned binary never reads the app's real token item (which would
// raise a Keychain prompt and block the run).
KeychainStore.service = "com.mikezielonka.scrt-link.e2e-tests.\(UUID().uuidString)"
SecKeychainSetUserInteractionAllowed(false)

// An unbundled binary gets its own UserDefaults domain, named after the
// executable, so history, preferences and window frames never touch the app's.
let defaults = UserDefaults.standard
let defaultsDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
defaults.removePersistentDomain(forName: defaultsDomain)

// The app copies links to the general clipboard. Remember what was there and
// put it back at the end (string content only; best effort).
let clipboard = NSPasteboard.general
let savedClipboard = clipboard.string(forType: .string)

/// Every copy of a bearer link must also declare org.nspasteboard.ConcealedType
/// so clipboard managers skip it (audit S4).
func isConcealed(_ pb: NSPasteboard) -> Bool {
    pb.types?.contains(SecurePasteboard.concealedType) == true
        && pb.string(forType: SecurePasteboard.concealedType) != nil
}

// MARK: - Test helpers

var failures = 0
var checks = 0

@MainActor
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)  (line \(line))")
    }
}

@MainActor
func finish() -> Never {
    clipboard.clearContents()
    if let savedClipboard { clipboard.setString(savedClipboard, forType: .string) }
    defaults.removePersistentDomain(forName: defaultsDomain)
    print("")
    print("═══════════════════════════════════════════")
    print("  Checks: \(checks)   Failed: \(failures)")
    print("═══════════════════════════════════════════")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
func fail(_ message: String) -> Never {
    print("  ✗ \(message)")
    failures += 1
    finish()
}

/// Pumps the main run loop (WebKit callbacks, main-actor tasks, notifications)
/// until `condition` holds or `timeout` elapses.
@discardableResult
@MainActor
func spin(timeout: Double, until condition: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

@MainActor
func allSubviews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allSubviews(of: $0) }
}

@MainActor
func labels(in view: NSView) -> [String] {
    allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
}

@MainActor
func button(titled title: String, in view: NSView) -> NSButton? {
    allSubviews(of: view).compactMap { $0 as? NSButton }.first { $0.title == title }
}

/// What the fake client module was asked to create, decoded from the link it
/// returned (`https://scrt.link/s#<percent-encoded JSON>`).
struct FakeCall {
    let text: String
    let opts: [String: Any]

    init?(link: String) {
        guard let hash = link.range(of: "#"),
              let json = String(link[hash.upperBound...]).removingPercentEncoding,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              let opts = object["opts"] as? [String: Any] else { return nil }
        self.text = text
        self.opts = opts
    }
}

// MARK: - Harness fixture

let harnessPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/harness.html"
guard let realHarness = try? String(contentsOfFile: harnessPath, encoding: .utf8) else {
    print("  ✗ could not read \(harnessPath)")
    exit(1)
}
let moduleURL = "https://scrt.link/api/v1/client-module"
let fakeToken = "e2e-fake-token"

// The fake module behaves like scrt.link's: it takes (apiKey, text, opts) and
// resolves { secretLink, receiptId, expiresAt }. The link fragment carries
// what it was given so the test can assert every option made the trip.
let fakeModule = """
export default (apiKey) => ({
    createSecret: async (text, opts) => {
        if (apiKey !== '\(fakeToken)') throw new Error('wrong token');
        if (text === 'fail-me') throw new Error('api says no');
        const payload = encodeURIComponent(JSON.stringify({ text, opts: opts || {} }));
        return {
            secretLink: 'https://scrt.link/s#' + payload,
            receiptId: 'rcpt-' + text.length,
            expiresAt: new Date(Date.now() + ((opts && opts.expiresIn) || 0)).toISOString(),
        };
    },
});
"""
let encodedModule = fakeModule.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
let workingHarness = realHarness.replacingOccurrences(of: moduleURL, with: "data:text/javascript," + encodedModule)

print("▸ Fixture")
check(realHarness.contains("'\(moduleURL)'"), "real harness imports the scrt.link client module")

// Embedded web UI trust boundary (audit S1, S2): exact host match and a
// web-only scheme allowlist for anything handed to the default browser.
print("▸ Web view trust boundary")
check(WebViewController.isTrustedHost("scrt.link", customHost: ""), "scrt.link is trusted")
check(WebViewController.isTrustedHost("SCRT.LINK", customHost: ""), "host comparison ignores case")
check(WebViewController.isTrustedHost("app.scrt.link", customHost: ""), "subdomains of scrt.link are trusted")
check(!WebViewController.isTrustedHost("scrt.link.example.com", customHost: ""), "scrt.link.example.com is not trusted")
check(!WebViewController.isTrustedHost("notscrt.link", customHost: ""), "notscrt.link is not trusted")
check(!WebViewController.isTrustedHost("scrt.linkattacker.com", customHost: ""), "scrt.linkattacker.com is not trusted")
check(!WebViewController.isTrustedHost(nil, customHost: ""), "a URL without a host is not trusted")
check(WebViewController.isTrustedHost("secrets.example.com", customHost: " Secrets.Example.com "),
      "the configured custom host is trusted")
check(!WebViewController.isTrustedHost("secrets.example.com", customHost: ""), "a custom host is only trusted when configured")
check(!WebViewController.isTrustedHost("example.com", customHost: "secrets.example.com"), "the custom host's parent domain is not trusted")
for bad in ["tel:+15555550100", "file:///etc/hosts", "x-apple.systempreferences:com.apple.preference.security",
            "javascript:alert(1)", "mailto:a@b.c", "custom-scheme://payload", "http:", "https://"] {
    if let url = URL(string: bad) {
        check(!WebViewController.openInBrowser(url), "\(bad) is never handed to NSWorkspace")
    } else {
        check(true, "\(bad) does not even parse as a URL")
    }
}

// Custom host validation (audit S6): the token is sent to this host, so only
// a bare hostname is accepted.
print("▸ Custom host validation")
check(Preferences.normalizedCustomHost("") == "", "empty clears the setting")
check(Preferences.normalizedCustomHost("secrets.example.com") == "secrets.example.com", "plain hostname is accepted")
check(Preferences.normalizedCustomHost("  HTTPS://Secrets.Example.com/  ") == "secrets.example.com",
      "scheme, slashes, whitespace and case are normalized away")
check(Preferences.normalizedCustomHost("http://secrets.example.com") == "secrets.example.com", "http:// prefix is tolerated")
for bad in ["secrets.example.com:8443", "secrets.example.com/api", "user@secrets.example.com",
            "secrets.example.com?x=1", "secrets.example.com#frag", "localhost", "secrets", ".example.com",
            "example.com.", "secrets example.com", "https://", "scrt.link/../evil.example"] {
    check(Preferences.normalizedCustomHost(bad) == nil, "\(bad) is refused")
}

// Harness CSP (audit S7): scripts from scrt.link only, connections to
// scrt.link plus the configured custom host, nothing else.
print("▸ Harness content security policy")
let appCSP = ScrtLinkAPI.contentSecurityPolicy(customHost: "")
check(appCSP.contains("default-src 'none'"), "everything not listed is blocked")
check(appCSP.contains("script-src 'unsafe-inline' https://scrt.link;"), "scripts: inline bootstrap and scrt.link only")
check(appCSP.contains("connect-src https://scrt.link;"), "connections: scrt.link only when no custom host is set")
check(!appCSP.contains("data:"), "the app's own policy never allows data: scripts")
let hostCSP = ScrtLinkAPI.contentSecurityPolicy(customHost: "https://Secrets.Example.com/")
check(hostCSP.contains("connect-src https://scrt.link https://secrets.example.com;"), "a configured custom host is allowed, normalized")
check(ScrtLinkAPI.contentSecurityPolicy(customHost: "not a host").contains("connect-src https://scrt.link;"),
      "an invalid custom host is not added to the policy")
let document = ScrtLinkAPI.harnessDocument(realHarness, contentSecurityPolicy: appCSP)
if let metaAt = document.range(of: "http-equiv=\"Content-Security-Policy\"")?.lowerBound,
   let scriptAt = document.range(of: "<script")?.lowerBound {
    check(metaAt < scriptAt, "CSP meta precedes the first script in the harness document")
} else {
    check(false, "CSP meta or script tag missing from the harness document")
}

@MainActor
func makeAPI(token: String) -> ScrtLinkAPI {
    // `data:` lets the inline fake module through the CSP in tests only.
    ScrtLinkAPI(harnessHTML: { workingHarness }, tokenProvider: { token }, timeoutSeconds: 10, extraScriptSources: ["data:"])
}
let offlineAPI = makeAPI(token: fakeToken)
ScrtLinkAPI.shared = offlineAPI

// MARK: - Build the real app UI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)  // no Dock icon, no focus steal
let delegate = AppDelegate()
app.delegate = delegate

print("")
print("▸ Main window")
let controller = WebViewController()
globalWebViewController = controller
guard let mainWindow = app.windows.first(where: { $0.title == "Scrt.link" }),
      let content = mainWindow.contentView else { fail("main window was not created") }
spin(timeout: 0.3)  // the split position is applied on the next run-loop turn
content.layoutSubtreeIfNeeded()
check(!controller.hasWebView, "no embedded web view is created at launch in native mode")

guard let split = content as? NSSplitView else { fail("native mode content is not the split view") }
check(split.arrangedSubviews.count == 2, "split view has sidebar and form panes")
guard let sidebar = allSubviews(of: content).compactMap({ $0 as? HistorySidebarView }).first
else { fail("sidebar not found") }
guard let form = allSubviews(of: content).compactMap({ $0 as? NativeSecretFormView }).first
else { fail("native form not found") }
check(split.arrangedSubviews[0].frame.width > 200, "sidebar pane is laid out (\(Int(split.arrangedSubviews[0].frame.width)) pt wide)")

// Form controls, located the way a user sees them.
let formViews = allSubviews(of: form)
guard let textView = formViews.compactMap({ $0 as? NSScrollView }).compactMap({ $0.documentView as? NSTextView }).first
else { fail("secret text view not found") }
let popups = formViews.compactMap { $0 as? NSPopUpButton }
guard let typePopup = popups.first(where: { $0.itemTitles.contains("Redirect URL") }),
      let expPopup = popups.first(where: { $0.itemTitles.contains("10 minutes") })
else { fail("type / expiration popups not found") }
guard let passwordField = formViews.compactMap({ $0 as? NSSecureTextField }).first
else { fail("password field not found") }
guard let noteField = formViews.compactMap({ $0 as? NSTextField })
    .first(where: { $0.placeholderString?.hasPrefix("Optional public note") == true })
else { fail("public note field not found") }
guard let createButton = button(titled: "Create Secret", in: form) else { fail("Create Secret button not found") }
guard let spinner = formViews.compactMap({ $0 as? NSProgressIndicator }).first,
      let statusLabel = spinner.superview?.subviews.compactMap({ $0 as? NSTextField }).first
else { fail("status label not found") }
guard let heading = formViews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "Secret created" }),
      let resultCard = heading.superview?.superview,
      let linkField = resultCard.subviews.compactMap({ $0 as? NSTextField }).first
else { fail("result card not found") }

check(typePopup.itemTitles == ["Text", "Redirect URL", "Neogram (auto-burn)"], "type choices: \(typePopup.itemTitles)")
check(expPopup.itemTitles == ["10 minutes", "1 hour", "24 hours", "7 days", "30 days"], "expiration choices: \(expPopup.itemTitles)")
check(expPopup.titleOfSelectedItem == "24 hours", "24 hours is the default expiration")
check(resultCard.isHidden, "result card starts hidden")
check(statusLabel.stringValue.isEmpty, "status label starts empty")
check(createButton.isEnabled && spinner.isHidden, "Create is enabled and the spinner hidden at rest")

// Sidebar pieces.
guard let sidebarScroll = allSubviews(of: sidebar).compactMap({ $0 as? NSScrollView }).first,
      let cardStack = sidebarScroll.documentView as? NSStackView
else { fail("sidebar card list not found") }
guard let sidebarEmpty = allSubviews(of: sidebar).compactMap({ $0 as? NSTextField })
    .first(where: { $0.stringValue.hasPrefix("No secrets in the last 24 hours") })
else { fail("sidebar empty-state label not found") }
guard let clearHistoryButton = button(titled: "Clear History", in: sidebar),
      let viewLogButton = button(titled: "View Full Log…", in: sidebar)
else { fail("sidebar footer buttons not found") }
guard let accountLink = allSubviews(of: sidebar).compactMap({ $0 as? NSButton })
    .first(where: { $0.attributedTitle.string.contains("connected") })
else { fail("account status link not found") }

@MainActor func cardLabels() -> [String] {
    cardStack.arrangedSubviews.compactMap { labels(in: $0).first }
}

print("")
print("▸ Empty state")
check(cardStack.arrangedSubviews.isEmpty, "no cards before any secret")
check(!sidebarEmpty.isHidden, "empty-state message is shown")
check(clearHistoryButton.isHidden, "Clear History is hidden while the log is empty")
check(accountLink.attributedTitle.string == "Not connected · Set API token",
      "account row says not connected (no token in this Keychain service)")
accountLink.performClick(nil)
check(delegate.preferencesOpened == 1, "clicking the account row opens Preferences when no token is set")
viewLogButton.performClick(nil)
check(delegate.secretLogOpened == 1, "View Full Log… asks the app to open the Secret Log")

// MARK: - Error paths

print("")
print("▸ Empty secret")
textView.string = "  \n\t "
createButton.performClick(nil)
check(statusLabel.stringValue == "Secret can't be empty.", "status: \(statusLabel.stringValue)")
check(statusLabel.textColor == .systemRed, "status is shown as an error")
check(createButton.isEnabled, "Create stays enabled")
check(SecretHistoryStore.load().isEmpty, "nothing was logged")

print("")
print("▸ Missing token")
ScrtLinkAPI.shared = makeAPI(token: "")
textView.string = "hello"
createButton.performClick(nil)
spin(timeout: 2) { statusLabel.stringValue != "Encrypting and uploading…" }
check(statusLabel.stringValue == "No API token configured. Set it in Preferences.", "status: \(statusLabel.stringValue)")
check(statusLabel.textColor == .systemRed, "status is shown as an error")
check(textView.string == "hello", "the secret text is kept so the user can retry")
check(createButton.isEnabled && spinner.isHidden, "form is idle again")
check(SecretHistoryStore.load().isEmpty, "nothing was logged")
ScrtLinkAPI.shared = offlineAPI

// MARK: - Happy path: text secret with every option

print("")
print("▸ Create a text secret with password and note")
textView.string = "the launch codes"
typePopup.selectItem(withTitle: "Text")
expPopup.selectItem(withTitle: "10 minutes")
passwordField.stringValue = "pw-123"
noteField.stringValue = "Board deck"
clipboard.clearContents()
clipboard.setString("clipboard-before", forType: .string)
let beforeCreate = Date()

createButton.performClick(nil)
check(!createButton.isEnabled, "Create is disabled while the request is in flight")
check(!spinner.isHidden, "spinner is shown while the request is in flight")
check(statusLabel.stringValue == "Encrypting and uploading…", "status: \(statusLabel.stringValue)")
check(resultCard.isHidden, "previous result is hidden while a new one is in flight")

check(spin(timeout: 15) { createButton.isEnabled }, "request completes")
check(!resultCard.isHidden, "result card is shown")
let firstLink = linkField.stringValue
check(firstLink.hasPrefix("https://scrt.link/s#"), "result card shows a scrt.link link")
if let call = FakeCall(link: firstLink) {
    check(call.text == "the launch codes", "secret text reached the client module")
    check(call.opts["secretType"] as? String == "text", "secretType = text")
    check(call.opts["expiresIn"] as? Int == 10 * 60 * 1000, "expiresIn = 10 minutes in ms")
    check(call.opts["password"] as? String == "pw-123", "password was passed")
    check(call.opts["publicNote"] as? String == "Board deck", "public note was passed")
    check(call.opts["host"] == nil, "no custom host by default")
} else {
    check(false, "could not decode the fake module's call from \(firstLink)")
}
check(statusLabel.stringValue == "Link copied to clipboard", "status: \(statusLabel.stringValue)")
check(statusLabel.textColor == .secondaryLabelColor, "status is not an error")
check(clipboard.string(forType: .string) == firstLink, "the link is on the clipboard")
check(isConcealed(clipboard), "the auto-copied link is marked concealed for clipboard managers")
check(textView.string.isEmpty, "secret text is cleared after success")
check(passwordField.stringValue.isEmpty, "password is cleared after success")
check(noteField.stringValue.isEmpty, "note is cleared after success")

let afterFirst = SecretHistoryStore.load()
check(afterFirst.count == 1, "history has one entry")
if let entry = afterFirst.first {
    check(entry.link == firstLink, "stored link matches the result card")
    check(entry.secretType == "text" && entry.publicNote == "Board deck", "stored type and note")
    check(entry.displayLabel == "Board deck", "note is the display label")
    check(entry.receiptId == "rcpt-16", "receipt id stored")
    if let exp = entry.expiresAt {
        let expected = beforeCreate.addingTimeInterval(600)
        check(abs(exp.timeIntervalSince(expected)) < 60, "expiresAt parsed from the API (\(Int(exp.timeIntervalSince(beforeCreate))) s ahead)")
    } else {
        check(false, "expiresAt was not parsed")
    }
}

content.layoutSubtreeIfNeeded()
check(cardLabels() == ["Board deck"], "sidebar shows the new card: \(cardLabels())")
check(sidebarEmpty.isHidden, "empty-state message is hidden")
check(!clearHistoryButton.isHidden, "Clear History appears")
if let card = cardStack.arrangedSubviews.first {
    let subtitle = labels(in: card).dropFirst().first ?? ""
    check(subtitle.hasPrefix("Text secret · "), "card subtitle names the type: \(subtitle)")
    check(subtitle.contains("expires"), "card subtitle shows the expiration")
    check(!labels(in: card).contains { $0.contains("scrt.link/s#") }, "card does not render the bearer link")
    clipboard.clearContents()
    button(titled: "Copy", in: card)?.performClick(nil)
    check(clipboard.string(forType: .string) == firstLink, "card's Copy puts the link on the clipboard")
    check(isConcealed(clipboard), "card's Copy marks the link concealed for clipboard managers")
}

print("")
print("▸ Diagnostic report stays free of secrets")
var report: String?
ScrtLinkAPI.shared.runDiagnostic { report = $0 }
spin(timeout: 5) { report != nil }
check(report != nil, "diagnostic report is produced")
check(!(report ?? "").contains("the launch codes"), "report omits the secret text")
check(!(report ?? "").contains("pw-123"), "report omits the password")
check(!(report ?? "").contains(fakeToken), "report omits the API token")
check(!(report ?? "").contains("scrt.link/s#"), "report omits the link")

// MARK: - Redirect with a custom host

print("")
print("▸ Create a redirect on a custom domain")
Preferences.customHost = "secrets.example.test"
textView.string = "https://example.com/handbook"
typePopup.selectItem(withTitle: "Redirect URL")
expPopup.selectItem(withTitle: "7 days")
createButton.performClick(nil)
check(spin(timeout: 15) { createButton.isEnabled }, "request completes")
let secondLink = linkField.stringValue
if let call = FakeCall(link: secondLink) {
    check(call.text == "https://example.com/handbook", "redirect target reached the client module")
    check(call.opts["secretType"] as? String == "redirect", "secretType = redirect")
    check(call.opts["expiresIn"] as? Int == 7 * 24 * 60 * 60 * 1000, "expiresIn = 7 days in ms")
    check(call.opts["host"] as? String == "secrets.example.test", "custom host was passed")
    check(call.opts["password"] == nil, "no password when the field is empty")
    check(call.opts["publicNote"] == nil, "no note when the field is empty")
} else {
    check(false, "could not decode the fake module's call from \(secondLink)")
}
Preferences.customHost = ""
let afterSecond = SecretHistoryStore.load()
check(afterSecond.count == 2, "history has two entries")
check(afterSecond.first?.link == secondLink, "newest entry is first")
check(afterSecond.first?.displayLabel == "Redirect", "label falls back to the type name")
content.layoutSubtreeIfNeeded()
check(cardLabels() == ["Redirect", "Board deck"], "sidebar is newest-first: \(cardLabels())")

// MARK: - API failure

print("")
print("▸ API failure")
textView.string = "fail-me"
typePopup.selectItem(withTitle: "Text")
createButton.performClick(nil)
check(spin(timeout: 15) { createButton.isEnabled }, "request completes")
check(statusLabel.stringValue.contains("api says no"), "status shows the API error: \(statusLabel.stringValue)")
check(statusLabel.textColor == .systemRed, "status is shown as an error")
check(resultCard.isHidden, "no result card for a failed request")
check(textView.string == "fail-me", "the secret text is kept so the user can retry")
check(SecretHistoryStore.load().count == 2, "nothing was logged for the failure")

// MARK: - Services / hotkey prefill

print("")
print("▸ Services menu prefill forces the native form")
Preferences.useWebUI = true  // as if the user had switched to the web UI
let servicePasteboard = NSPasteboard(name: NSPasteboard.Name("scrt-link-e2e-\(UUID().uuidString)"))
servicePasteboard.declareTypes([.string], owner: nil)
servicePasteboard.setString("from the services menu", forType: .string)
var serviceError: NSString?
ServiceProvider().createScrtLinkSecret(servicePasteboard, userData: nil, error: &serviceError)
servicePasteboard.releaseGlobally()
check(serviceError == nil, "service reports no error")
check(Preferences.useWebUI == false, "web UI preference is switched off")
check(mainWindow.contentView === split, "window shows the native split view again")
check(textView.string == "from the services menu", "secret text is prefilled")
check(textView.selectedRange() == NSRange(location: 0, length: "from the services menu".utf16.count),
      "prefilled text is selected for quick replacement")
check(mainWindow.firstResponder === textView, "secret text view has focus")

// MARK: - Secret Log window

print("")
print("▸ Secret Log window")
let log = SecretLogWindow()
guard let logWindow = app.windows.first(where: { $0.title == "Secret Log" }),
      let logContent = logWindow.contentView,
      let table = allSubviews(of: logContent).compactMap({ $0 as? NSTableView }).first,
      let searchField = allSubviews(of: logContent).compactMap({ $0 as? NSSearchField }).first,
      let copyLinkButton = button(titled: "Copy Link", in: logContent),
      let deleteButton = button(titled: "Delete", in: logContent)
else { fail("Secret Log window pieces not found") }
_ = log
logContent.layoutSubtreeIfNeeded()

@MainActor func cellText(row: Int, column: Int) -> String? {
    (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
}
check(table.numberOfRows == 2, "log lists both secrets")
let logLabels = (0..<table.numberOfRows).compactMap { cellText(row: $0, column: 1) }
check(logLabels == ["Redirect", "Board deck"], "log rows are newest-first: \(logLabels)")
let rendered = (0..<table.numberOfRows).flatMap { row in (0..<table.numberOfColumns).compactMap { cellText(row: row, column: $0) } }
check(!rendered.contains { $0.contains("scrt.link/s#") }, "no bearer link is rendered in the table")
check(!copyLinkButton.isEnabled && !deleteButton.isEnabled, "Copy Link and Delete are disabled with no selection")

table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
check(copyLinkButton.isEnabled, "Copy Link enables on selection")
clipboard.clearContents()
copyLinkButton.performClick(nil)
check(clipboard.string(forType: .string) == firstLink, "Copy Link copies the selected row's link")
check(isConcealed(clipboard), "Copy Link marks the link concealed for clipboard managers")

searchField.stringValue = "board"
searchField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: searchField))
check(table.numberOfRows == 1 && cellText(row: 0, column: 1) == "Board deck", "filter narrows to the matching row")
check(labels(in: logContent).contains("1 of 2 secrets"), "count label reflects the filter")
searchField.stringValue = ""
searchField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: searchField))
check(table.numberOfRows == 2, "clearing the filter restores every row")

table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
deleteButton.performClick(nil)
check(SecretHistoryStore.load().count == 1, "Delete removes the selected record")
check(table.numberOfRows == 1 && cellText(row: 0, column: 1) == "Board deck", "table drops the deleted row")
content.layoutSubtreeIfNeeded()
check(cardLabels() == ["Board deck"], "sidebar drops the deleted card too: \(cardLabels())")

print("")
print("▸ Clear history")
SecretHistoryStore.clear()
content.layoutSubtreeIfNeeded()
check(cardStack.arrangedSubviews.isEmpty && !sidebarEmpty.isHidden, "sidebar returns to its empty state")
check(clearHistoryButton.isHidden, "Clear History hides again")
check(table.numberOfRows == 0, "log table is empty")
check(labels(in: logContent).contains("No secrets logged yet."), "log shows its empty message")

print("")
print("▸ Web view stays lazy")
check(!controller.hasWebView, "the embedded web view was never created during native-mode use")

finish()
