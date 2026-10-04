#!/bin/bash
set -euo pipefail

# Build a Developer ID signed, notarized, stapled archive. Publishing is an
# explicit second step so a failed notarization can never create a release.
#
# Usage: TEAM_ID=... DEVELOPER_ID='Developer ID Application: ...' \
#        NOTARY_PROFILE=scrt-link ./release.sh 1.6.1 [--publish]

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   { [[ -n "$PUBLISH" ]] && [[ "$PUBLISH" != "--publish" ]]; }; then
    echo "Usage: TEAM_ID=... DEVELOPER_ID=... NOTARY_PROFILE=... ./release.sh <version> [--publish]" >&2
    exit 2
fi

: "${TEAM_ID:?Set the Apple Developer team ID}"
: "${DEVELOPER_ID:?Set the Developer ID Application signing identity}"
: "${NOTARY_PROFILE:?Set a notarytool Keychain profile}"
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "TEAM_ID must be a 10-character Apple team ID" >&2
    exit 2
fi

cd "$(dirname "$0")"
PLIST_VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
if [[ "$PLIST_VERSION" != "$VERSION" || "$BUILD_VERSION" != "$VERSION" ]]; then
    echo "Set both Info.plist version fields to $VERSION before releasing" >&2
    exit 1
fi

if [[ "$PUBLISH" == "--publish" ]]; then
    [[ "$(git branch --show-current)" == "main" ]] || { echo "Publish from main only" >&2; exit 1; }
    [[ -z "$(git status --porcelain)" ]] || { echo "Publish from a clean checkout" >&2; exit 1; }
    command -v gh >/dev/null || { echo "gh CLI is required to publish" >&2; exit 1; }
    git fetch --quiet origin main
    HEAD_SHA="$(git rev-parse HEAD)"
    [[ "$HEAD_SHA" == "$(git rev-parse refs/remotes/origin/main)" ]] || {
        echo "Local main differs from origin/main; push or update before publishing" >&2
        exit 1
    }
    [[ -z "$(git ls-remote --tags origin "refs/tags/v$VERSION")" ]] || {
        echo "Tag v$VERSION already exists on origin" >&2
        exit 1
    }
fi

./build.sh
APP_BUNDLE=".build/ScrtLink.app"
ZIP_FILE=".build/ScrtLink-v$VERSION.zip"

# This value is sealed by the app signature and pins the team for future
# in-app updates. Local ad hoc builds omit it and cannot auto-install updates.
plutil -insert ScrtLinkTeamID -string "$TEAM_ID" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$APP_BUNDLE"
REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and identifier \"com.mikezielonka.scrt-link\""
codesign --verify --deep --strict -R="$REQUIREMENT" "$APP_BUNDLE"

./package.sh "$APP_BUNDLE" "$ZIP_FILE"
NOTARY_OPTIONS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    NOTARY_OPTIONS+=(--keychain "$NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$ZIP_FILE" "${NOTARY_OPTIONS[@]}" --wait
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE"
codesign --verify --deep --strict -R="$REQUIREMENT" "$APP_BUNDLE"

# The ticket is attached to the app, so archive the stapled bundle again.
./package.sh "$APP_BUNDLE" "$ZIP_FILE"
echo "Ready: $ZIP_FILE"

if [[ "$PUBLISH" == "--publish" ]]; then
    gh release create "v$VERSION" "$ZIP_FILE" \
        --repo mikezielonkadotcom/scrt.link-mac-app \
        --target "$HEAD_SHA" \
        --title "v$VERSION" \
        --notes "Scrt.link v$VERSION" \
        --latest
fi
