# Tests

## Smoke test

```bash
./tests/smoke.sh
```

What it checks:

| Step | What |
|------|------|
| 1 | All source files + required resources exist |
| 2 | `Info.plist` is valid and has the right bundle id / executable name |
| 3 | `build.sh` succeeds |
| 4 | Built bundle contains an arm64 Mach-O binary, all expected resources, and a structurally valid code signature |
| 5 | App launches and survives for 5 seconds without crashing |
| 6 | *(Best-effort)* System Events sees a window + menu bar item |
| 7 | App terminates cleanly |

The script runs on your dev machine — it actually launches a GUI. Step 6 needs Accessibility permission granted to your shell (System Settings → Privacy & Security → Accessibility → add Terminal/iTerm). Without it, step 6 is skipped with a warning rather than failing.

## History store test

```bash
./tests/test-history-store.sh
```

Compiles `Sources/SecretHistoryStore.swift` with `tests/HistoryStoreTests/main.swift` and runs it against a throwaway `UserDefaults` suite. Covers newest-first ordering, the 24-hour recent window and its rolling age-out, remove/clear, the 500-entry cap, and loading legacy unsorted data. No GUI, no permissions.

## UI layout test

```bash
./tests/test-ui-layout.sh
```

Compiles every app source except `main.swift` together with `tests/UILayoutTests/main.swift` (which supplies a stub `AppDelegate` and points the token lookup at a throwaway Keychain service), builds the real `HistorySidebarView` and `SecretLogWindow` in offscreen windows, and inspects the view tree: flipped clip view, newest card on top, list opens scrolled to the top even when it overflows, only the last 24 h in the sidebar, every entry in the log table, no bearer link rendered. Runs headless — no Screen Recording or Accessibility permission needed, so it works in a plain shell where `smoke.sh`'s UI probe cannot.

## Keychain store test

```bash
./tests/test-keychain-store.sh
```

Compiles `Sources/KeychainStore.swift` with `tests/KeychainStoreTests/main.swift`. Points `KeychainStore.service` at a throwaway service unique to the run, so the app's real token item is never read or changed, and deletes its test item before exit. Keychain user interaction is disabled, so a locked keychain fails fast instead of prompting. Covers the empty state, migration of a legacy `UserDefaults` token, save and clear, and a newer legacy token left by an older build (for example after rolling back to 1.6.0) replacing a stale Keychain value without leaving a plaintext copy.

## Secret-creation bridge test

```bash
./tests/test-scrtlink-api.sh
```

Compiles `Sources/ScrtLinkAPI.swift` (plus `KeychainStore.swift` and `Preferences.swift`) with `tests/ScrtLinkAPITests/main.swift` and drives the real `Resources/harness.html` in a real `WKWebView`, with only the scrt.link client-module import swapped for an inline fake. No network, no scrt.link account, no Keychain access (the token is injected). Covers the happy path, the diagnostic report omitting the secret text, token and link, recovery after the client module failed to load, an earlier request's timeout not failing a later request, and a timed-out request's late result not completing a later request. Takes about 20 seconds.

## Why not XCUITest / full e2e?

This is a thin WKWebView wrapper around scrt.link. The interesting behavior (creating a secret, encrypting client-side) lives in their web app, not ours. Full UI e2e would mostly be testing them, and would break whenever they redesign the form. The smoke test above covers ~90% of real regressions for a small AppKit wrapper.
