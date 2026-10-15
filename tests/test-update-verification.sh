#!/bin/bash
# Offline regression test for the auto-updater's release gates.
#
# Compiles Sources/UpdateManager.swift with tests/UpdateManagerTests/main.swift
# and runs it against the ad hoc build in .build/ScrtLink.app. Covers the
# numeric version comparison, the download URL pinning (exact asset name,
# https, github.com, this repository's releases path, no lookalike hosts), and
# the bundle verification that must refuse anything that is not Developer ID
# signed by the pinned team: a local ad hoc build, a missing or malformed team
# ID, a wrong bundle ID, a wrong version, or a missing bundle.
#
# No network, no Keychain, no alerts, no app launch. The positive signing path
# (a real Developer ID bundle passing) is exercised by the signed-release
# workflow's "Verify the distributable archive" step.
#
# Run: ./tests/test-update-verification.sh
# Exits 0 on success, non-zero on any failure.

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/tests"
BIN="$OUT_DIR/update-manager-tests"
APP=".build/ScrtLink.app"
mkdir -p "$OUT_DIR"

echo "▸ Build the ad hoc app bundle"
./build.sh >"$OUT_DIR/update-verification-build.log" 2>&1 || { cat "$OUT_DIR/update-verification-build.log"; exit 1; }
echo "  ✓ $APP"
echo ""

echo "▸ Compile"
swiftc \
    Sources/UpdateManager.swift \
    tests/UpdateManagerTests/main.swift \
    -o "$BIN" \
    -framework AppKit \
    -target arm64-apple-macosx14.0 \
    -swift-version 6
echo "  ✓ compiled $BIN"
echo ""

"$BIN" "$APP"
