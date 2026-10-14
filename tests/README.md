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

## Release archive test

```bash
./tests/test-release-archive.sh
```

Builds the app ad hoc, gives every file an extended attribute (macOS adds `com.apple.provenance` to built files), archives it with `package.sh`, and extracts it the way both in-app updaters do: `unzip -o` plus `xattr -cr` (1.6.0 and earlier) and `ditto -x -k` (1.6.1 and later). Each extracted bundle must pass `codesign --verify --deep --strict`. A control archive made without `--norsrc` must break the `unzip` path, proving the test detects the AppleDouble `._*` files that would otherwise land inside the bundle. No signing identity, network, Keychain, or app launch needed.

## End-to-end native flow test

```bash
./tests/test-e2e-native-flow.sh
```

Compiles every app source except `main.swift` with `tests/E2ENativeFlowTests/main.swift`, then builds the **real** main window (`WebViewController`: split view, `HistorySidebarView`, `NativeSecretFormView`) and the real `SecretLogWindow`, and drives them the way a user does. It installs an offline `ScrtLinkAPI` whose harness is the real `Resources/harness.html` with only the scrt.link client-module import swapped for an inline fake that echoes the text and options it received into the link.

Covers, in order: the empty state and footer actions; an empty secret; a missing token; a text secret with password and note (busy state, result card, clipboard, cleared fields, stored entry with parsed `expiresAt`, sidebar card, card Copy); the diagnostic report omitting text, password, token and link; a redirect on a custom domain with a 7-day expiry; an API failure that keeps the text and logs nothing; the Services-menu prefill forcing the native form (preference flipped, text prefilled and selected, focus); the Secret Log window (rows, no link rendered, selection-driven Copy Link, filter and count label, Delete propagating to the sidebar); and Clear History. About 100 checks, roughly 15 seconds, no network, no scrt.link account, no access to the app's Keychain item or history.

It does use the general clipboard (the app copies links there) and restores the previous string afterwards. Switching *into* web mode is not exercised because that loads `https://scrt.link/` for real. Like the bridge test, it leaves a `~/Library/WebKit/e2e-native-flow-tests` data directory behind.

## Update verification test

```bash
./tests/test-update-verification.sh
```

Builds the ad hoc app, compiles `Sources/UpdateManager.swift` with `tests/UpdateManagerTests/main.swift`, and checks the updater's release gates offline: the numeric version comparison, the download URL pinning (exact asset name, https, `github.com`, this repository's releases path, rejecting lookalike hosts, userinfo and port tricks, other repositories and path traversal), and `verifyUpdate` refusing the ad hoc build under every variation (no team ID, malformed team ID, wrong bundle ID, wrong version, missing bundle, and a correct team ID with an ad hoc signature). No network, no Keychain, no alerts, no app launch. The positive case, a Developer ID bundle passing, is exercised by the signed-release workflow's archive verification step.

## Why not XCUITest?

There is no Xcode project, and `smoke.sh` / `test-autoupdate.sh` already cover the launched-app checks that need Accessibility permission. The in-process suites above test the real AppKit views and the real harness HTML without any permission prompts, so they run in a plain shell and on the CI runner. Only scrt.link's own encryption module is faked.
