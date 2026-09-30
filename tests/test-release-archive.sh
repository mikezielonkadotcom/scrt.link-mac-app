#!/bin/bash
# Regression test for the release archive (package.sh).
#
# Builds the app ad hoc, gives every file an extended attribute (as macOS does
# with com.apple.provenance), archives it with package.sh, then extracts it
# the way both in-app updaters do and checks the code signature:
#   - 1.6.0 and earlier: `unzip -o` + `xattr -cr`
#   - 1.6.1 and later:   `ditto -x -k`
# A control archive made without --norsrc must break the 1.6.0 path, which
# proves the test can see the failure it guards against.
#
# No signing identity, network, Keychain, or app launch needed.
#
# Run: ./tests/test-release-archive.sh
# Exits 0 on success, non-zero on any failure.

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scrtlink-archive-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Build"
./build.sh >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }
ditto .build/ScrtLink.app "$WORK/src/ScrtLink.app"
find "$WORK/src/ScrtLink.app" -exec xattr -w com.mikezielonka.scrt-link.test 1 {} \;
if codesign --verify --deep --strict "$WORK/src/ScrtLink.app" 2>/dev/null; then
    pass "built bundle with extended attributes has a valid signature"
else
    fail "built bundle signature is invalid before archiving"
fi

# Extract like the 1.6.0 updater: unzip, take the first .app, strip xattrs.
extract_legacy() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"
    unzip -q -o "$zip" -d "$dest"
    xattr -cr "$dest/ScrtLink.app"
}

echo ""
echo "▸ package.sh archive"
./package.sh "$WORK/src/ScrtLink.app" "$WORK/release.zip"
entries="$(unzip -Z1 "$WORK/release.zip")"
if grep -qE '(^|/)\._|^__MACOSX/' <<<"$entries"; then
    fail "archive contains AppleDouble entries"
else
    pass "archive has no AppleDouble or __MACOSX entries"
fi
if [ "$(grep -cE '^[^/]+\.app/$' <<<"$entries")" = "1" ] && grep -q '^ScrtLink.app/$' <<<"$entries"; then
    pass "archive has exactly one top-level app, ScrtLink.app"
else
    fail "archive top level is not exactly ScrtLink.app"
fi

extract_legacy "$WORK/release.zip" "$WORK/legacy"
if codesign --verify --deep --strict "$WORK/legacy/ScrtLink.app" 2>/dev/null; then
    pass "1.6.0 updater extraction (unzip + xattr -cr) keeps a valid signature"
else
    fail "1.6.0 updater extraction breaks the signature"
fi

mkdir -p "$WORK/current"
ditto -x -k "$WORK/release.zip" "$WORK/current"
if codesign --verify --deep --strict "$WORK/current/ScrtLink.app" 2>/dev/null; then
    pass "1.6.1 updater extraction (ditto -x -k) keeps a valid signature"
else
    fail "1.6.1 updater extraction breaks the signature"
fi

echo ""
echo "▸ Control: archive without --norsrc"
ditto -c -k --keepParent "$WORK/src/ScrtLink.app" "$WORK/control.zip"
extract_legacy "$WORK/control.zip" "$WORK/control"
if codesign --verify --deep --strict "$WORK/control/ScrtLink.app" 2>/dev/null; then
    fail "control archive unexpectedly survived unzip; the test cannot detect the regression"
else
    pass "control archive breaks the 1.6.0 extraction, as expected"
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "═══════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
