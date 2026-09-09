# Scrt.link Mac App

> **Unofficial third-party client for [scrt.link](https://scrt.link/).** Not affiliated with or endorsed by scrt.link. See [Disclaimers](#disclaimers) below.

Native macOS app for creating one-time-view encrypted secrets via [scrt.link](https://scrt.link/). Lives in your menu bar (and optionally the Dock), keeps a local history of links you've made, and works through either a native AppKit form or the embedded scrt.link website.

All encryption happens client-side inside the app — scrt.link's servers never see plaintext.

---

## Features

- **Native secret form** — type, pick expiration, click Create. No browser needed.
- **Recent-secrets sidebar** — links from the last 24 hours, newest at the top, with label, type, expiration, and one-click re-copy. Older links age out of the sidebar automatically.
- **Secret Log window** — the full local history (up to 500 links) in a searchable table with Copy / Open / Delete. `⌘L`, the sidebar's **View Full Log…** button, or the menu bar icon's right-click menu.
- **Menu bar quick-access** — click the menu bar icon to toggle the window from anywhere; `⌘,` for Preferences.
- **Embedded Web UI fallback** — toggle on in Preferences if you need to create file secrets (not supported by the API).
- **Client-side encryption** — secrets are encrypted in-app before upload using scrt.link's official JS client module (AES-GCM via WebCrypto).
- **Local history** — last 500 secrets, no plaintext stored (only the link + metadata). Wipeable from the sidebar or the Secret Log window.
- **GitHub-backed auto-update** — new releases prompt in-app and install in place.
- **Launch at Login** — via `SMAppService`, no helper app needed.

---

## Install

Download the latest `.zip` from [Releases](https://github.com/mikezielonkadotcom/scrt.link-mac-app/releases), unzip, drag `ScrtLink.app` into `/Applications`, launch.

First launch: right-click `ScrtLink.app` → **Open** → **Open** to bypass Gatekeeper (the app is unsigned).

---

## Setup

The native form uses scrt.link's API, which requires a paid subscription.

1. Open the app and click **Preferences…** (menu bar icon → Preferences, or `⌘,`)
2. Paste your scrt.link **bearer token** (generate one from your scrt.link account page)
3. Click **Save**

No paid plan? Toggle **Use Web UI instead of native form** in Preferences to use scrt.link's free embedded site instead.

---

## Usage

### Create a secret

1. Pick a **Type**: Text, Redirect URL, or Neogram (auto-burn message)
2. Type your secret in the main text area
3. Pick **Expires in** (10 min / 1 hour / 24 hours / 7 days / 30 days)
4. *(Optional)* set a **Password** and/or **Public note** (the note becomes the label in your history)
5. Click **Create Secret**

On success:
- The link is copied to your clipboard
- Shown in the result field with Copy / Open buttons
- Added to the **Recent** sidebar on the left

### Recent sidebar

- Shows links created in the **last 24 hours**, newest at the top, with label · type · relative time · expiration
- Entries older than 24 hours drop off the sidebar on their own (checked once a minute) — they are **not** deleted, just moved out of the way
- **Copy** re-copies the link to clipboard
- **Open** opens the link in your default browser — **note: this consumes the secret's one-time view**
- **View Full Log…** opens the Secret Log window
- **Clear** wipes all local records, recent and full log (doesn't affect the secrets on scrt.link)

### Secret Log window

Everything the app has ever logged (capped at the newest 500), newest first. Open it with `⌘L` (View → Secret Log…), the sidebar's **View Full Log…** button, or the menu bar icon's right-click menu.

- Columns: Created · Label · Type · Expires · Receipt. The link itself is never displayed — it is a bearer credential — use **Copy Link** instead.
- Filter box searches label, type, and receipt ID
- **Copy Link** (`⌘C` or double-click), **Open**, **Delete** (or ⌫) act on the selected row(s); right-click for the same actions
- **Clear Log…** wipes all local records after confirmation

### Web UI mode

For file secrets or free-tier usage:
- Preferences → **Use Web UI instead of native form**
- Main window swaps to scrt.link's embedded site
- Cookies persist so you stay logged in

---

## Preferences

| Setting | What it does |
|---|---|
| Launch at Login | Starts the app on login (`SMAppService`) |
| Show in Dock | Toggles `.regular` ↔ `.accessory` activation policy |
| API Token | Bearer token for scrt.link API (stored in UserDefaults) |
| Use Web UI | Swaps native form for embedded scrt.link web view |
| Clear Website Data | Clears cookies/cache for the embedded web view |

---

## How it works

scrt.link **enforces client-side encryption** — their REST endpoint rejects raw plaintext. The supported integration path is their JavaScript client module, which handles the encryption before calling their API.

This app wraps that constraint:

1. You type a secret in the native AppKit form
2. Swift passes the inputs to a hidden `WKWebView` loaded at `https://scrt.link/` baseURL
3. The WebView's harness HTML imports scrt.link's client module from `/api/v1/client-module`
4. The module encrypts client-side (AES-GCM + PBKDF2) and POSTs to `/api/v1/secrets`
5. The returned `{ secretLink, receiptId, expiresAt }` arrives back in Swift via `WKScriptMessageHandler`
6. Swift stores the link in local history and copies it to the clipboard

No plaintext ever leaves your device in the clear. The decryption key lives only in the URL's `#` fragment, which never hits the server.

Full technical write-up: [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Troubleshooting

**"No API token configured"**
Set your bearer token in Preferences. The native form requires it.

**Create Secret hangs forever**
Press `⌘D` (or View → **Run API Diagnostic**). The dialog dumps Swift state, WebView state, and a per-step JS log — paste the output when filing an issue.

**"Update Check Failed"**
Needs internet; hits `api.github.com/repos/mikezielonkadotcom/scrt.link-mac-app/releases/latest`.

**App won't launch on first run**
Right-click `ScrtLink.app` → **Open** → **Open**. macOS Gatekeeper blocks unsigned apps by default.

---

## Build

Swift 6+, macOS 14+.

```bash
./build.sh
open .build/ScrtLink.app
```

Raw `swiftc` — no Xcode project, no SwiftPM.

## Release

```bash
./release.sh 1.3.0
```

Bumps `Resources/Info.plist`, builds, zips, creates a GitHub release via `gh` (or curl fallback).

## Tests

```bash
./tests/smoke.sh           # build + launch + UI probe (28+ checks)
./tests/test-autoupdate.sh # end-to-end auto-update flow
```

See [tests/README.md](tests/README.md) for what each step covers.

---

## Disclaimers

**Unofficial client.** This project is not affiliated with, endorsed by, or sponsored by scrt.link or its operators. It's a third-party client that uses scrt.link's publicly documented API module. The scrt.link name and logo belong to their respective owners and appear here only to identify the service this app integrates with.

**Use at your own risk.** The code is provided as-is under the terms in [LICENSE](LICENSE), with no warranty of any kind. The author(s) are not liable for any damages, data loss, disclosure of secrets, or other harm resulting from use of this app. Before sharing anything sensitive, verify with scrt.link's own interface that the integration behaves as you expect.

**Respect scrt.link's Terms of Service.** By configuring an API token and creating secrets through this app, you agree to abide by scrt.link's ToS and rate limits. Don't use this client to abuse their service. If scrt.link changes their API or client module in a way that breaks this app, updates may lag behind.

**Unsigned binary.** Releases are not code-signed or notarized. macOS Gatekeeper will warn before first launch; right-click → Open to bypass. If you're deploying this in an environment that requires notarization, build from source and sign it yourself.

**No plaintext storage — but links are sensitive.** The app never stores the plaintext of your secrets. It does store the shareable links locally (in `UserDefaults` under `scrtLinkHistory`) along with metadata like type, expiration, and public note. **A scrt.link URL is effectively a bearer credential for that secret** — its `#<key>` fragment is the decryption key. Treat your history the same way you'd treat any credential list: clear it if the device is shared, compromised, or resold. "Clear" in the sidebar or "Clear Log…" in the Secret Log window wipes local records (it does not affect the secrets themselves on scrt.link).

**API token security.** Your scrt.link bearer token is stored in `UserDefaults` (not Keychain — Keychain prompts on every access for unsigned apps, which broke iteration). Treat it with the same care as any other account credential. If you suspect it's been exposed, regenerate it on scrt.link and update it in Preferences.

**Analytics / telemetry.** None. This app makes two categories of network calls: (1) requests to `https://scrt.link/api/*` to create secrets, and (2) an update check against `api.github.com/repos/mikezielonkadotcom/scrt.link-mac-app/releases/latest` shortly after launch. Nothing is sent anywhere else.

---

Built by [Mike Zielonka](https://mikezielonka.com). Unofficial client — not affiliated with scrt.link.
