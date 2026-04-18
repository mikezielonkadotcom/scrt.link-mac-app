#!/bin/bash
# End-to-end test of the GitHub-release-based auto-update flow.
#
# Strategy:
#   1. Temporarily downgrade Info.plist to v0.0.1
#   2. Rebuild
#   3. Launch the app
#   4. Wait ~7s for the update check + network fetch
#   5. Assert an "Update Available" alert appears (button "Update Now" exists)
#   6. Kill the app, restore Info.plist, rebuild at the real version
#
# Run: ./tests/test-autoupdate.sh
# Exits 0 on success, non-zero on any failure.
# Requires: Accessibility permission for the shell (System Settings →
# Privacy & Security → Accessibility → add Terminal/iTerm) and network
# access to api.github.com.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ScrtLink"
BUNDLE_PATH=".build/$APP_NAME.app"
PLIST="Resources/Info.plist"
BACKUP="/tmp/scrtlink-plist-backup-$$.plist"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "▸ Auto-update e2e"

# Capture the real version so we can restore byte-for-byte after
cp "$PLIST" "$BACKUP"

cleanup() {
    echo ""
    echo "▸ Cleanup"
    pkill -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 1
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$PLIST"
        rm -f "$BACKUP"
        echo "  ✓ Info.plist restored"
        # Rebuild at the real version so the on-disk bundle isn't stale
        if ./build.sh >/tmp/scrtlink-autoupdate-rebuild.log 2>&1; then
            echo "  ✓ rebuilt at real version"
        else
            echo "  ! rebuild failed — see /tmp/scrtlink-autoupdate-rebuild.log"
        fi
    fi
}
trap cleanup EXIT

# ---- 1. downgrade version ----------------------------------------------

REAL_VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
echo "  real version: $REAL_VERSION"

# Rewrite both CFBundleVersion and CFBundleShortVersionString to 0.0.1
plutil -replace CFBundleVersion -string "0.0.1" "$PLIST"
plutil -replace CFBundleShortVersionString -string "0.0.1" "$PLIST"
pass "Info.plist temporarily set to 0.0.1"

# ---- 2. rebuild ---------------------------------------------------------

if ./build.sh >/tmp/scrtlink-autoupdate-build.log 2>&1; then
    pass "rebuilt with spoofed v0.0.1"
else
    fail "build failed"
    tail -20 /tmp/scrtlink-autoupdate-build.log
    exit 1
fi

# ---- 3. launch ----------------------------------------------------------

pkill -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1

open "$BUNDLE_PATH"
sleep 2
if pgrep -f "$BUNDLE_PATH/Contents/MacOS/$APP_NAME" >/dev/null; then
    pass "app launched"
else
    fail "app failed to launch"
    exit 1
fi

echo "  ▸ waiting 7s for 3s-delayed update check + GitHub fetch..."
sleep 7

# ---- 4. assert the alert appeared --------------------------------------

RESULT=$(osascript 2>/dev/null <<'APPLESCRIPT' || echo "OSA_ERROR"
tell application "System Events"
    if not (exists (processes where bundle identifier is "com.mikezielonka.scrt-link")) then
        return "NO_PROCESS"
    end if
    tell process "ScrtLink"
        set hasUpdateNow to false
        set hasLater to false
        -- NSAlert buttons expose the label as title (not name), and the
        -- alert window has an empty name with AXDialog subrole, so scan
        -- every window and match buttons by title.
        repeat with w in windows
            try
                repeat with b in buttons of w
                    try
                        set t to title of b
                        if t is "Update Now" then set hasUpdateNow to true
                        if t is "Later" then set hasLater to true
                    end try
                end repeat
            end try
        end repeat
        return (hasUpdateNow as string) & "|" & (hasLater as string)
    end tell
end tell
APPLESCRIPT
)

case "$RESULT" in
    OSA_ERROR)
        fail "osascript failed — likely missing Accessibility permission for this shell"
        ;;
    NO_PROCESS)
        fail "System Events could not see the process"
        ;;
    true\|true)
        pass "'Update Available' alert visible"
        pass "'Update Now' button present"
        pass "'Later' button present"
        ;;
    true\|false)
        pass "'Update Now' button present"
        fail "'Later' button missing"
        ;;
    false\|*)
        fail "no update alert detected — flow broken or GitHub unreachable"
        ;;
esac

# ---- summary ------------------------------------------------------------

echo ""
echo "═══════════════════════════════════════════"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "═══════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
