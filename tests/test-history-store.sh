#!/bin/bash
# Unit-style regression test for SecretHistoryStore.
#
# Compiles Sources/SecretHistoryStore.swift together with
# tests/HistoryStoreTests/main.swift into a throwaway binary and runs it against an
# isolated UserDefaults suite (never touches the real app's history).
#
# Covers: newest-first ordering, the 24-hour "recent" window, rolling
# age-out without deletion, remove/clear, the maxEntries cap, and loading
# legacy unsorted data.
#
# Run: ./tests/test-history-store.sh
# Exits 0 on success, non-zero on any failure.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/history-store-tests"
mkdir -p "$OUT_DIR"

echo "▸ Compile"
swiftc \
    Sources/SecretHistoryStore.swift \
    tests/HistoryStoreTests/main.swift \
    -o "$BIN" \
    -framework Foundation \
    -target arm64-apple-macosx14.0 \
    -swift-version 6
echo "  ✓ compiled $BIN"
echo ""

"$BIN"
