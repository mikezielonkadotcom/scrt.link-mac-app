#!/bin/bash
# In-process end-to-end test of the native secret flow.
#
# Compiles every app source except Sources/main.swift together with
# tests/E2ENativeFlowTests/main.swift (which supplies a stub AppDelegate), then
# builds the REAL main window, sidebar, form and Secret Log window and drives
# them the way a user does: type a secret, pick options, click Create, and
# follow the link through the result card, the clipboard, the history store,
# the sidebar card and the Secret Log row. Also covers the empty-secret,
# missing-token and API-failure paths, the Services/hotkey prefill, and the
# forced switch back to the native form.
#
# The only thing swapped is the scrt.link client-module import inside the real
# Resources/harness.html, replaced by an inline fake. No network, no scrt.link
# account, no access to the app's Keychain item or history. The general
# clipboard is used (the app copies links to it) and restored afterwards.
#
# Run: ./tests/test-e2e-native-flow.sh
# Exits 0 on success, non-zero on any failure. Takes about 15 seconds.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/e2e-native-flow-tests"
mkdir -p "$OUT_DIR"

sources=()
for f in Sources/*.swift; do
    [ "$f" = "Sources/main.swift" ] && continue
    sources+=("$f")
done

echo "▸ Compile"
swiftc \
    "${sources[@]}" \
    tests/E2ENativeFlowTests/main.swift \
    -o "$BIN" \
    -framework AppKit \
    -framework WebKit \
    -framework ServiceManagement \
    -framework Security \
    -framework Carbon \
    -target arm64-apple-macosx14.0 \
    -swift-version 6
echo "  ✓ compiled $BIN"
echo ""

"$BIN" Resources/harness.html
