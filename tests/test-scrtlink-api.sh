#!/bin/bash
# Offline regression test for the secret-creation bridge (ScrtLinkAPI).
#
# Compiles Sources/ScrtLinkAPI.swift, KeychainStore.swift and Preferences.swift
# with tests/ScrtLinkAPITests/main.swift. The test drives the real
# Resources/harness.html in a real WKWebView, with only the scrt.link client
# module import swapped for an inline fake. No network, no scrt.link account,
# no Keychain access (the token is injected), no app launch.
#
# Run: ./tests/test-scrtlink-api.sh
# Exits 0 on success, non-zero on any failure. Takes about 20 seconds.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/scrtlink-api-tests"
mkdir -p "$OUT_DIR"

echo "▸ Compile"
swiftc \
    Sources/ScrtLinkAPI.swift \
    Sources/KeychainStore.swift \
    Sources/Preferences.swift \
    tests/ScrtLinkAPITests/main.swift \
    -o "$BIN" \
    -framework AppKit \
    -framework WebKit \
    -framework Security \
    -framework Carbon \
    -target arm64-apple-macosx14.0 \
    -swift-version 6
echo "  ✓ compiled $BIN"
echo ""

"$BIN" Resources/harness.html
