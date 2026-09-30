# Architecture

Technical deep-dive. For user-facing info, see [README.md](README.md).

## High-level

```
┌───────────────────────────────────────────────────────┐
│                    AppKit / Swift                      │
│                                                        │
│   ┌──────────────┐        ┌───────────────────────┐   │
│   │ Menu bar     │        │   Main window         │   │
│   │ status item  │        │   ┌───────────────┐   │   │
│   └──────────────┘        │   │  NSSplitView  │   │   │
│                           │   │ ┌───┬───────┐ │   │   │
│                           │   │ │His│ Form  │ │   │   │
│                           │   │ │   │       │ │   │   │
│                           │   │ └───┴───────┘ │   │   │
│                           │   └───────────────┘   │   │
│                           └───────────────────────┘   │
│                                                        │
│   ┌──────────────────────────────────────────────┐    │
│   │           ScrtLinkAPI (shared)                │    │
│   │                                               │    │
│   │  ┌─────────────────────────────────────────┐  │    │
│   │  │  hidden WKWebView                       │  │    │
│   │  │  baseURL = https://scrt.link/           │  │    │
│   │  │                                         │  │    │
│   │  │  ┌───────────────────────────────────┐  │  │    │
│   │  │  │  harness.html (bundled resource)  │  │  │    │
│   │  │  │                                   │  │  │    │
│   │  │  │  import '/api/v1/client-module'   │  │  │    │
│   │  │  │  window.scrtCreate = async (...) │  │  │    │
│   │  │  └───────────────────────────────────┘  │  │    │
│   │  └─────────────────────────────────────────┘  │    │
│   └──────────────────────────────────────────────┘    │
└───────────────────────┬────────────────────────────────┘
                        │ fetch POST (same-origin)
                        ▼
             ┌──────────────────────┐
             │  scrt.link           │
             │  /api/v1/secrets     │
             └──────────────────────┘
```

## Swift ↔ JavaScript bridge

Three message channels, all via `WKScriptMessageHandler`:

| Channel | Direction | Purpose |
|---|---|---|
| `scrtReady` | JS → Swift | Signals harness stages (`document-loaded`, `module-loaded`) |
| `scrtResult` | JS → Swift | Returns the `{ link, receiptId, expiresAt }` result or an error |
| `scrtLog` | JS → Swift | Per-step debug log, visible in the Run API Diagnostic dialog |

Swift → JS is one-way via `evaluateJavaScript`. To avoid the "unsupported type" error when calling async JS, the invocation is wrapped in `void`:

```swift
let js = "void window.scrtCreate(\(tokenLit), \(textLit), \(optsJSON));"
webView.evaluateJavaScript(js) { _, err in ... }
```

## Key design decisions

### 1. Hidden WebView instead of reimplementing the crypto in Swift

scrt.link's encryption format is proprietary and undocumented. Reimplementing it in Swift would mean tracking their client module source and staying in lockstep with upstream changes. The ~40-line HTML harness that imports their module is far smaller, faster to ship, and auto-syncs with whatever crypto they deploy.

### 2. `baseURL: https://scrt.link/` for `loadHTMLString`

Setting the WebView's baseURL to scrt.link makes the page's origin match, so:
- `import 'https://scrt.link/api/v1/client-module'` is same-origin (no CORS)
- The module's subsequent POST to `/api/v1/secrets` is same-origin (no preflight)

### 3. `void` before the async call

`window.scrtCreate(...)` is async and returns a `Promise`. WKWebView's `evaluateJavaScript` can't serialize a promise back to Swift — it calls the completion handler with an `NSError` of "unsupported type" (error domain `WKErrorDomain`, code 5). An earlier build treated that benign error as a failure and cleared `pending`, so when the real result arrived ~400 ms later via `postMessage`, `handleResult` ignored it (pending was already nil) — a silent hang.

Fix: wrap the call in `void`, which makes the expression evaluate to `undefined` (serializable). The real result comes back via the `scrtResult` message.

Each call also passes a request ID that the harness echoes in its `scrtResult` message. Only the matching request's result or 15-second timeout can complete it, so an earlier request's timer or late result can't complete, or fail, a newer one. A failed client-module import is reported as fatal, and a failed harness load or a terminated web content process marks the harness failed. The next Create reloads the harness instead of waiting behind one that will never become ready.

### 4. `JSONSerialization` with `.fragmentsAllowed`

By default, `JSONSerialization` refuses top-level scalars (Strings, Numbers, Bools) — it throws. The original code used `try?`, so the throw silently returned `nil`, which made the JS expression look like `window.scrtCreate(, , {...})` — a syntax error — and the call hung.

`.fragmentsAllowed` lets it encode any JSON-compatible value, including bare strings for the token and secret text.

### 5. Keychain for the API token

Developer ID releases have a stable signing identity, so the account-scoped bearer token lives in macOS Keychain. The first read migrates a token from older `UserDefaults` storage only after a successful Keychain write. Local ad hoc builds may prompt for Keychain access after a rebuild because their signing identity is not stable.

### 6. Secret ↔ link model; why we don't store plaintext

scrt.link's threat model: the decryption key lives in the URL's `#` fragment, which is never sent to the server. Whoever has the link can decrypt and view the secret **once**.

This app only stores the link, the receipt ID, and metadata (type, public note, expiration) — never the plaintext. Storing plaintext would defeat the one-time-view guarantee if the device were compromised. The link itself is functionally a bearer token for that secret; users should treat the history sidebar accordingly.

`SecretHistoryStore` exposes two views over one JSON array in `UserDefaults`:

- `load()` — the full log, always sorted newest-first on read (so legacy arrays written in insertion order display correctly), capped at 500 entries.
- `recent(now:)` — the subset created in the last 24 hours. The sidebar renders only this, so it "clears itself" on a rolling basis without ever deleting anything; a once-a-minute timer re-renders it so relative times and the cutoff stay current.

The sidebar's scroll view uses a flipped `NSClipView`. AppKit's default clip view is bottom-anchored, which pinned a short list to the bottom of the pane and opened a long list scrolled to the oldest entry — the newest card was the one you couldn't see.

`SecretLogWindow` is a plain `NSTableView` over `load()`. It never renders the URL column; Copy / Open / Delete act on the selection.

### 7. Raw `swiftc` build, no Xcode project

`build.sh` invokes `swiftc` directly and hand-assembles the `.app` bundle (`Contents/MacOS/`, `Contents/Resources/`, `Info.plist`). No Xcode project, no SwiftPM, no third-party dependencies. This keeps the repo dead-simple — any developer can read every build step in a 40-line shell script.

## File layout

```
scrt.link-mac-app/
├── Sources/
│   ├── main.swift                   NSApplicationDelegate, menu, app entry
│   ├── StatusBarController.swift    Menu bar icon + right-click menu
│   ├── WebViewController.swift      Main window, NSSplitView, mode switching
│   ├── NativeSecretFormView.swift   The form (AppKit, NSStackView layout)
│   ├── HistorySidebarView.swift     Left-pane list of the last 24 h (cards)
│   ├── SecretLogWindow.swift        Full-history table window (⌘L)
│   ├── SecretHistoryStore.swift     UserDefaults-backed history (recent + full)
│   ├── ScrtLinkAPI.swift            Hidden WebView + Swift↔JS bridge
│   ├── PreferencesWindow.swift      Preferences panel
│   ├── Preferences.swift            Simple toggle storage (useWebUI)
│   ├── KeychainStore.swift          API token storage and legacy migration
│   ├── BrandStyle.swift             Brand colors + button styling helpers
│   ├── DockManager.swift            Show/hide Dock toggle
│   └── UpdateManager.swift          GitHub Releases auto-updater
├── Resources/
│   ├── Info.plist
│   ├── AppIcon.icns
│   ├── StatusBarIcon.png            Template image for menu bar (auto-tinted)
│   ├── StatusBarIcon@2x.png
│   └── harness.html                 ~40 lines of JS that run scrt.link's client module
├── tests/
│   ├── smoke.sh
│   ├── test-autoupdate.sh
│   └── README.md
├── build.sh
├── release.sh
└── README.md
```

## Auto-update flow

1. 3 seconds after launch (and on-demand via menu), `UpdateManager.checkForUpdatesInBackground()` hits `api.github.com/repos/mikezielonkadotcom/scrt.link-mac-app/releases/latest`.
2. Compares `tag_name` (minus `v` prefix) against `CFBundleShortVersionString` via a numeric dotted-version compare.
3. If newer, prompts the user with release notes and download / defer buttons.
4. On accept: downloads the exact versioned ZIP, extracts it to a temp dir, checks the bundle ID, version, pinned Apple Developer team, signature, and Gatekeeper assessment, then stages it beside the installed app. The old app moves to a hidden backup beside the installed app before relaunch. If installation or LaunchServices fails, the updater attempts to restore the backup and reports any rollback failure. It keeps the backup after a successful relaunch for manual recovery.

This only works because the repo is **public** — `/releases/latest` returns 404 for private repos without authentication, which silently no-ops the check.

## Menu bar icon as a template

`StatusBarIcon.png` and `@2x` are monochrome silhouettes rendered at 18×18 and 36×36. They're tagged `isTemplate = true`, so macOS auto-tints them to match the menu bar (black in light mode, white in dark mode, and accent color on click). The source SVG is the scrt.link logo flattened to solid black on transparent.
