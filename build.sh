#!/bin/bash
set -e

APP="ScrtLink"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

swiftc \
  Sources/main.swift \
  Sources/DockManager.swift \
  Sources/Preferences.swift \
  Sources/KeychainStore.swift \
  Sources/BrandStyle.swift \
  Sources/SecretHistoryStore.swift \
  Sources/HistorySidebarView.swift \
  Sources/ScrtLinkAPI.swift \
  Sources/NativeSecretFormView.swift \
  Sources/StatusBarController.swift \
  Sources/WebViewController.swift \
  Sources/PreferencesWindow.swift \
  Sources/UpdateManager.swift \
  -o "$APP_BUNDLE/Contents/MacOS/$APP" \
  -framework AppKit \
  -framework WebKit \
  -framework ServiceManagement \
  -framework Security \
  -target arm64-apple-macosx14.0 \
  -swift-version 6

cp Resources/Info.plist "$APP_BUNDLE/Contents/"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp Resources/StatusBarIcon.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp Resources/StatusBarIcon@2x.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
cp Resources/harness.html "$APP_BUNDLE/Contents/Resources/"

xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "Built: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
echo ""
echo "To install: cp -r $APP_BUNDLE /Applications/"
