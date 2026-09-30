#!/bin/bash
# Regression test for KeychainStore token storage and legacy migration.
#
# Compiles Sources/KeychainStore.swift with tests/KeychainStoreTests/main.swift
# and runs it against a throwaway Keychain service and this binary's own
# UserDefaults domain. It never reads or changes the app's real token item.
# Keychain user interaction is disabled, so a locked keychain fails fast
# instead of prompting.
#
# Run: ./tests/test-keychain-store.sh
# Exits 0 on success, non-zero on any failure.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/keychain-store-tests"
mkdir -p "$OUT_DIR"

echo "▸ Compile"
swiftc \
    Sources/KeychainStore.swift \
    tests/KeychainStoreTests/main.swift \
    -o "$BIN" \
    -framework Foundation \
    -framework Security \
    -target arm64-apple-macosx14.0 \
    -swift-version 6
echo "  ✓ compiled $BIN"
echo ""

"$BIN"
