import AppKit

// Headless AppKit layout test, compiled by tests/test-ui-layout.sh together
// with every app source except Sources/main.swift (this file supplies a stub
// AppDelegate instead). Builds the real HistorySidebarView and SecretLogWindow
// in offscreen windows and inspects the view tree — no screen recording or
// accessibility permission required.
//
// Guards the regressions this feature fixed:
//   - sidebar list is top-anchored (flipped clip view) and opens scrolled to top
//   - newest secret is the FIRST card
//   - sidebar only shows the last 24 h; the log window shows everything

// Stubs of the globals main.swift normally provides, so the other sources
// compile unchanged. Never invoked here.
var globalWebViewController: WebViewController?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func openPreferences() {}
    @objc func openSecretLog() {}
}

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
func allSubviews(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allSubviews(of: $0) }
}

/// First text field inside a view, in tree order (a card's title label).
@MainActor
func firstLabel(in view: NSView) -> String? {
    allSubviews(of: view).compactMap { ($0 as? NSTextField)?.stringValue }.first
}

// --- Seed history in THIS process's defaults domain -------------------------
// An unbundled binary gets its own domain (named after the executable), so
// this never touches the real app's history. Cleaned up at the end.
let defaults = UserDefaults.standard
let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
defaults.removePersistentDomain(forName: domain)

let now = Date()
let hour: TimeInterval = 3600
func seed(_ label: String, ageHours: Double) {
    SecretHistoryStore.add(SecretEntry(
        createdAt: now.addingTimeInterval(-ageHours * hour),
        link: "https://scrt.link/s#test-\(label)",
        receiptId: "rcpt-\(label)",
        secretType: "text",
        publicNote: label
    ))
}
// Oldest first on purpose: the UI must not depend on insertion order.
seed("three-days-old", ageHours: 72)
seed("thirty-hours-old", ageHours: 30)
seed("twenty-hours-old", ageHours: 20)
seed("two-hours-old", ageHours: 2)
seed("newest", ageHours: 0.01)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)  // no Dock icon, no focus steal

// --- Sidebar ----------------------------------------------------------------
print("▸ Sidebar")
let host = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false
)
let sidebar = HistorySidebarView(frame: host.contentView!.bounds)
sidebar.translatesAutoresizingMaskIntoConstraints = false
host.contentView!.addSubview(sidebar)
NSLayoutConstraint.activate([
    sidebar.topAnchor.constraint(equalTo: host.contentView!.topAnchor),
    sidebar.bottomAnchor.constraint(equalTo: host.contentView!.bottomAnchor),
    sidebar.leadingAnchor.constraint(equalTo: host.contentView!.leadingAnchor),
    sidebar.trailingAnchor.constraint(equalTo: host.contentView!.trailingAnchor),
])
sidebar.reload()
host.contentView!.layoutSubtreeIfNeeded()

@MainActor
func fail(_ message: String) -> Never {
    print("  ✗ \(message)")
    defaults.removePersistentDomain(forName: domain)
    exit(1)
}

guard let scroll = allSubviews(of: sidebar).compactMap({ $0 as? NSScrollView }).first,
      let stack = scroll.documentView as? NSStackView
else { fail("could not find the sidebar's scroll view / stack") }

let clip = scroll.contentView
check(clip.isFlipped, "clip view is flipped (list anchored to top)")
check(clip.bounds.origin.y == 0, "scrolled to top after reload (clip bounds origin.y == \(clip.bounds.origin.y))")
check(stack.frame.origin == .zero, "stack is pinned to the clip's top-left (\(stack.frame.origin))")

let cards = stack.arrangedSubviews
let cardLabels = cards.compactMap(firstLabel(in:))
check(cards.count == 3, "sidebar shows 3 cards (last 24 h only), got \(cards.count)")
check(cardLabels == ["newest", "two-hours-old", "twenty-hours-old"], "cards are newest-first: \(cardLabels)")
check(!cardLabels.contains("thirty-hours-old"), "30-hour-old entry is not in the sidebar")

// Measure in the (flipped) clip view's space, where y grows downward, so
// "smaller y" means "higher on screen" regardless of the stack's own space.
@MainActor func yInClip(_ card: NSView) -> CGFloat { stack.convert(card.frame, to: clip).minY }
if cards.count >= 2 {
    let firstY = yInClip(cards[0])
    let secondY = yInClip(cards[1])
    check(firstY < secondY, "first card is physically above the second (y \(firstY) < \(secondY))")
    check(firstY < 40, "first card hugs the top of the list (y = \(firstY))")
}

// A list taller than the viewport must still open at the top (the old
// unflipped clip view opened at the bottom, i.e. on the oldest entry).
for i in 0..<20 { seed("bulk-\(i)", ageHours: 0.5 + Double(i) * 0.1) }
sidebar.reload()
host.contentView!.layoutSubtreeIfNeeded()
check(stack.frame.height > clip.bounds.height, "tall list overflows the viewport (\(stack.frame.height) > \(clip.bounds.height))")
check(clip.bounds.origin.y == 0, "tall list opens scrolled to the top (origin.y == \(clip.bounds.origin.y))")
if let top = stack.arrangedSubviews.first {
    check(firstLabel(in: top) == "newest", "top card of the tall list is still the newest")
    check(yInClip(top) < 40, "top card is visible at the top of the viewport (y = \(yInClip(top)))")
}

// A reload with an unchanged entry set (what the minute timer does) must
// keep the user's scroll position and reuse the existing cards.
clip.scroll(to: NSPoint(x: 0, y: 300))
scroll.reflectScrolledClipView(clip)
let cardsBefore = stack.arrangedSubviews
sidebar.reload()
host.contentView!.layoutSubtreeIfNeeded()
check(clip.bounds.origin.y == 300, "timer-style reload keeps scroll position (origin.y == \(clip.bounds.origin.y))")
check(stack.arrangedSubviews.elementsEqual(cardsBefore, by: ===), "timer-style reload reuses the same card views")

// …but a change to the list (a new secret) reveals the top again.
seed("brand-new", ageHours: 0)
host.contentView!.layoutSubtreeIfNeeded()
check(clip.bounds.origin.y == 0, "new secret scrolls back to the top (origin.y == \(clip.bounds.origin.y))")
check(firstLabel(in: stack.arrangedSubviews.first!) == "brand-new", "new secret is the top card")
if let id = SecretHistoryStore.load().first(where: { $0.publicNote == "brand-new" })?.id {
    SecretHistoryStore.remove(id: id)
}
if let ids = Optional(Set(SecretHistoryStore.load().filter { ($0.publicNote ?? "").hasPrefix("bulk-") }.map(\.id))) {
    SecretHistoryStore.remove(ids: ids)
}

let sidebarButtons = allSubviews(of: sidebar).compactMap { $0 as? NSButton }.map(\.title)
check(sidebarButtons.contains("View Full Log…"), "sidebar has a View Full Log… button")
check(sidebarButtons.contains("Clear History"), "sidebar keeps a Clear History button")

// The card subtitle uses the same type names as the log window.
if let top = cards.first {
    let texts = allSubviews(of: top).compactMap { ($0 as? NSTextField)?.stringValue }
    check(texts.contains { $0.hasPrefix("Text secret · ") }, "card subtitle uses SecretEntry.typeName: \(texts)")
}

// Rolling age-out: no history change, time passes → 20 h entry leaves the list
// once it's older than 24 h. Simulate by rewriting createdAt and reloading,
// exactly what the minute timer would observe.
var entries = SecretHistoryStore.load()
if let idx = entries.firstIndex(where: { $0.publicNote == "twenty-hours-old" }) {
    entries[idx].createdAt = now.addingTimeInterval(-25 * hour)
    SecretHistoryStore.save(entries)
}
sidebar.reload()
let afterLabels = stack.arrangedSubviews.compactMap(firstLabel(in:))
check(afterLabels == ["newest", "two-hours-old"], "entry that crossed 24 h aged out on reload: \(afterLabels)")
check(SecretHistoryStore.load().count == 5, "…without deleting it from the full log")

// --- Log window -------------------------------------------------------------
print("▸ Secret Log window")
let log = SecretLogWindow()
guard let logWindow = app.windows.first(where: { $0.title == "Secret Log" }),
      let table = allSubviews(of: logWindow.contentView!).compactMap({ $0 as? NSTableView }).first
else { fail("could not find the Secret Log window / table") }
_ = log
logWindow.contentView!.layoutSubtreeIfNeeded()

check(table.numberOfRows == 5, "log table lists every entry (5), got \(table.numberOfRows)")
check(table.tableColumns.map(\.title) == ["Created", "Label", "Type", "Expires", "Receipt"],
      "columns: \(table.tableColumns.map(\.title))")

@MainActor func cellText(row: Int, column: Int) -> String? {
    (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
}
let labelColumn = 1
let logLabels = (0..<table.numberOfRows).compactMap { cellText(row: $0, column: labelColumn) }
check(logLabels == ["newest", "two-hours-old", "twenty-hours-old", "thirty-hours-old", "three-days-old"],
      "log rows are newest-first: \(logLabels)")

let renderedCells = (0..<table.numberOfRows).flatMap { row in
    (0..<table.numberOfColumns).compactMap { cellText(row: row, column: $0) }
}
check(!renderedCells.contains { $0.contains("scrt.link/s#") }, "no bearer link is rendered in the table")

let logButtons = allSubviews(of: logWindow.contentView!).compactMap { $0 as? NSButton }.map(\.title)
for title in ["Copy Link", "Open", "Delete", "Clear Log…"] {
    check(logButtons.contains(title), "log window has a \(title) button")
}

// Store change → both views refresh via notification.
if let victim = SecretHistoryStore.load().first(where: { $0.publicNote == "three-days-old" }) {
    SecretHistoryStore.remove(id: victim.id)
}
check(table.numberOfRows == 4, "log table refreshes after a delete (4 rows), got \(table.numberOfRows)")

// --- Cleanup ----------------------------------------------------------------
defaults.removePersistentDomain(forName: domain)

print("")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
