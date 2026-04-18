# scrt.link Mac App

A native macOS wrapper around [scrt.link](https://scrt.link/) for quick one-time secret sharing from the menu bar.

All encryption happens client-side in scrt.link's web app — this app is a thin WebKit wrapper that persists your session and gives you a menu bar + Dock shortcut.

## Features

- Menu bar icon (left-click to toggle window, right-click for menu)
- Window with back/forward/reload/home toolbar
- Persistent cookies so your paid account stays logged in
- Preferences: Launch at Login, Show in Dock, Clear Website Data
- Auto-update from GitHub releases

Any generated `scrt.link/s#…` secret URL opens in your default browser, not inside the app — so you don't accidentally burn your own secret by previewing it.

## Build

```bash
./build.sh
open .build/ScrtLink.app
```

Requires Swift 6+ and macOS 14+.

## Release

```bash
./release.sh 1.0.1
```

Bumps `Info.plist`, builds, zips, and creates a GitHub release via `gh`.

## Install

Download the latest `.zip` from [Releases](https://github.com/mikezielonkadotcom/scrt.link-mac-app/releases), unzip, drag `ScrtLink.app` into `/Applications`.
