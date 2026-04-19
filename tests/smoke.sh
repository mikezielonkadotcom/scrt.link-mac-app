#!/bin/bash
# Smoke / e2e test for ScrtLink.app.
#
# Verifies the app:
#   1. Has a valid Info.plist and all required resources
#   2. Builds cleanly
#   3. Produces a valid arm64 Mach-O binary
#   4. Launches without crashing in the first few seconds
#   5. Presents its main window (via AppleScript / System Events)
#
# Run: ./tests/smoke.sh
# Exits 0 on success, non-zero on any failure.
# Requires: a dev machine with Accessibility permission granted to Terminal
# (or whatever shell you run this from) for the UI probe step.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ScrtLink"
BUNDLE_PATH=".build/$APP_NAME.app"
BUNDLE_ID="com.mikezielonka.scrt-link"
PASS=0
FAIL=0
WARN=0

# ---- helpers ------------------------------------------------------------

pass()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
warn()  { echo "  ! $1"; WARN=$((WARN+1)); }
step()  { echo ""; echo "▸ $1"; }

cleanup() {
    pkill -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ---- 1. source file presence --------------------------------------------

step "Source tree"

required_sources=(
    "Sources/main.swift"
    "Sources/StatusBarController.swift"
    "Sources/WebViewController.swift"
    "Sources/PreferencesWindow.swift"
    "Sources/DockManager.swift"
    "Sources/UpdateManager.swift"
    "Sources/Preferences.swift"
    "Sources/KeychainStore.swift"
    "Sources/BrandStyle.swift"
    "Sources/SecretHistoryStore.swift"
    "Sources/HistorySidebarView.swift"
    "Sources/GlobalHotKey.swift"
    "Sources/ServiceProvider.swift"
    "Sources/ScrtLinkAPI.swift"
    "Sources/NativeSecretFormView.swift"
    "Resources/Info.plist"
    "Resources/AppIcon.icns"
    "Resources/StatusBarIcon.png"
    "Resources/StatusBarIcon@2x.png"
    "Resources/harness.html"
    "build.sh"
    "release.sh"
)

for f in "${required_sources[@]}"; do
    if [ -f "$f" ]; then pass "$f"; else fail "missing $f"; fi
done

# ---- 2. Info.plist validity ---------------------------------------------

step "Info.plist"

if plutil -lint Resources/Info.plist >/dev/null 2>&1; then
    pass "plutil lint passes"
else
    fail "plutil lint failed"
fi

plist_bundle_id=$(plutil -extract CFBundleIdentifier raw Resources/Info.plist 2>/dev/null || echo "")
if [ "$plist_bundle_id" = "$BUNDLE_ID" ]; then
    pass "CFBundleIdentifier = $BUNDLE_ID"
else
    fail "CFBundleIdentifier is '$plist_bundle_id', expected '$BUNDLE_ID'"
fi

plist_exec=$(plutil -extract CFBundleExecutable raw Resources/Info.plist 2>/dev/null || echo "")
if [ "$plist_exec" = "$APP_NAME" ]; then
    pass "CFBundleExecutable = $APP_NAME"
else
    fail "CFBundleExecutable is '$plist_exec', expected '$APP_NAME'"
fi

# Verify the Services menu entry is declared
services_message=$(plutil -extract NSServices.0.NSMessage raw Resources/Info.plist 2>/dev/null || echo "")
if [ "$services_message" = "createScrtLinkSecret" ]; then
    pass "NSServices entry declared (message=createScrtLinkSecret)"
else
    fail "NSServices NSMessage is '$services_message', expected 'createScrtLinkSecret'"
fi

services_name=$(plutil -extract NSServices.0.NSMenuItem.default raw Resources/Info.plist 2>/dev/null || echo "")
if [ "$services_name" = "Create Scrt.link Secret" ]; then
    pass "Services menu label = '$services_name'"
else
    fail "Services menu label wrong: '$services_name'"
fi

# ---- 3. build -----------------------------------------------------------

step "Build"

if ./build.sh >/tmp/scrtlink-build.log 2>&1; then
    pass "build.sh succeeded"
else
    fail "build.sh failed — see /tmp/scrtlink-build.log"
    tail -20 /tmp/scrtlink-build.log
    exit 1
fi

# ---- 4. bundle sanity ---------------------------------------------------

step "Built bundle"

if [ -d "$BUNDLE_PATH" ]; then
    pass "bundle exists at $BUNDLE_PATH"
else
    fail "bundle not produced"; exit 1
fi

BIN="$BUNDLE_PATH/Contents/MacOS/$APP_NAME"
if [ -x "$BIN" ]; then
    pass "executable present"
else
    fail "executable missing"
fi

if file "$BIN" | grep -q "Mach-O 64-bit executable arm64"; then
    pass "binary is arm64 Mach-O"
else
    fail "binary arch wrong: $(file "$BIN")"
fi

for r in AppIcon.icns StatusBarIcon.png StatusBarIcon@2x.png harness.html; do
    if [ -f "$BUNDLE_PATH/Contents/Resources/$r" ]; then
        pass "bundled resource: $r"
    else
        fail "bundle missing resource: $r"
    fi
done

if plutil -lint "$BUNDLE_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    pass "bundled Info.plist lints"
else
    fail "bundled Info.plist broken"
fi

# ---- 5. launch & survive ------------------------------------------------

step "Launch"

# Make sure nothing is already running
pkill -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

open "$BUNDLE_PATH"
sleep 3

PID=$(pgrep -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" || true)
if [ -n "$PID" ]; then
    pass "app launched (pid $PID)"
else
    fail "app did not launch or crashed within 3s"
    exit 1
fi

# Check still alive a moment later — catches slow crash-on-load
sleep 2
if kill -0 "$PID" 2>/dev/null; then
    pass "app still running after 5s"
else
    fail "app crashed between 3s and 5s"
fi

# ---- 6. UI probe (best-effort) ------------------------------------------

step "UI probe (requires Accessibility permission)"

# Is the app the frontmost / visible via System Events?
UI_RESULT=$(osascript 2>/dev/null <<'APPLESCRIPT' || echo "ERROR"
tell application "System Events"
    if exists (processes where bundle identifier is "com.mikezielonka.scrt-link") then
        tell process "ScrtLink"
            set winCount to count of windows
            set hasMenubar to (count of menu bar items of menu bar 2) > 0
            return (winCount as string) & "|" & (hasMenubar as string)
        end tell
    else
        return "NO_PROCESS"
    end if
end tell
APPLESCRIPT
)

if [ "$UI_RESULT" = "ERROR" ] || [ -z "$UI_RESULT" ]; then
    warn "AppleScript probe failed — likely missing Accessibility permission for this shell"
    warn "System Settings → Privacy & Security → Accessibility → add Terminal/iTerm"
elif [ "$UI_RESULT" = "NO_PROCESS" ]; then
    fail "System Events does not see the process"
else
    win_count="${UI_RESULT%|*}"
    has_menubar="${UI_RESULT#*|}"
    if [ "$win_count" -ge 1 ]; then
        pass "main window visible ($win_count window(s))"
    else
        fail "no windows visible"
    fi
    if [ "$has_menubar" = "true" ]; then
        pass "menu bar item present"
    else
        warn "menu bar item not detected (may need different menu bar index)"
    fi
fi

# ---- 7. shutdown --------------------------------------------------------

step "Shutdown"

if pkill -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null; then
    pass "app terminated cleanly"
    sleep 1
    if pgrep -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" >/dev/null; then
        fail "app still running after SIGTERM"
    fi
else
    warn "nothing to kill (app already exited)"
fi

# ---- summary ------------------------------------------------------------

echo ""
echo "═══════════════════════════════════════════"
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Warnings:$WARN"
echo "═══════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
