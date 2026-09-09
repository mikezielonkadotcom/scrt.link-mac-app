#!/bin/bash
# Headless AppKit layout test for the history sidebar and Secret Log window.
#
# Compiles every app source except Sources/main.swift together with
# tests/UILayoutTests/main.swift (which supplies a stub AppDelegate), builds
# the real views in offscreen windows, and inspects the view tree. Needs no
# Screen Recording or Accessibility permission, so it runs anywhere the
# toolchain does.
#
# Run: ./tests/test-ui-layout.sh
# Exits 0 on success, non-zero on any failure.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/ui-layout-tests"
mkdir -p "$OUT_DIR"

sources=()
for f in Sources/*.swift; do
    [ "$f" = "Sources/main.swift" ] && continue
    sources+=("$f")
done

echo "▸ Compile"
swiftc \
    "${sources[@]}" \
    tests/UILayoutTests/main.swift \
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

"$BIN"
