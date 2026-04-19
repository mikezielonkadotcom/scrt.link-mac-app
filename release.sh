#!/bin/bash
set -e

# @todo Sign and notarize the app before zipping.
#
# Currently we ship unsigned binaries — users see Gatekeeper warnings on
# first launch and have to right-click → Open. When Mike's ready with his
# Developer ID cert, plug in here between `./build.sh` and the `zip` step:
#
#   TEAM_ID="XXXXXXXXXX"
#   APPLE_ID="me@mikezielonka.com"
#   APP_PASSWORD="app-specific-password"   # appleid.apple.com
#
#   codesign --force --deep --timestamp \
#       --options runtime \
#       --sign "Developer ID Application: Mike Zielonka ($TEAM_ID)" \
#       "$APP_BUNDLE"
#
#   # (zip happens here)
#
#   xcrun notarytool submit "$ZIP_FILE" \
#       --apple-id "$APPLE_ID" \
#       --team-id "$TEAM_ID" \
#       --password "$APP_PASSWORD" \
#       --wait
#
#   # Staple the ticket into the .app, then re-zip
#   xcrun stapler staple "$APP_BUNDLE"
#   (cd "$BUILD_DIR" && rm "$ZIP_NAME" && zip -r "$ZIP_NAME" "$APP.app")
#
# After this lands we can also move the scrt.link bearer token back to
# Keychain (see Sources/KeychainStore.swift header comment) since
# Keychain won't re-prompt when the binary is stably signed.

# Usage: ./release.sh <version> [GITHUB_TOKEN]

if [ -z "$1" ]; then
    echo "Usage: ./release.sh <version> [GITHUB_TOKEN]"
    echo "Example: ./release.sh 1.0.1"
    exit 1
fi

VERSION="$1"
TOKEN="${2:-$GITHUB_TOKEN}"
REPO="mikezielonkadotcom/scrt.link-mac-app"
APP="ScrtLink"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP.app"
ZIP_NAME="$APP-v$VERSION.zip"
ZIP_FILE="$BUILD_DIR/$ZIP_NAME"

sed -i '' "s|<string>[0-9]*\.[0-9]*\.[0-9]*</string>|<string>$VERSION</string>|g" Resources/Info.plist

echo "Building v$VERSION..."
./build.sh

echo "Packaging..."
cd "$BUILD_DIR"
zip -r "$ZIP_NAME" "$APP.app"
cd ..

echo ""
echo "Built: $ZIP_FILE"

if command -v gh &> /dev/null; then
    echo "Creating GitHub release v$VERSION via gh..."
    gh release create "v$VERSION" \
        "$ZIP_FILE" \
        --title "v$VERSION" \
        --notes "Scrt.link v$VERSION" \
        --latest
    echo "Release v$VERSION published!"

elif [ -n "$TOKEN" ]; then
    echo "Creating GitHub release v$VERSION via API..."

    RELEASE_JSON=$(curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/releases" \
        -d "{\"tag_name\":\"v$VERSION\",\"name\":\"v$VERSION\",\"body\":\"Scrt.link v$VERSION\",\"draft\":false,\"prerelease\":false}")

    UPLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"upload_url": "[^"]*"' | sed 's/"upload_url": "//;s/"//' | sed 's/{.*//')

    if [ -z "$UPLOAD_URL" ]; then
        echo "Failed to create release. Response:"
        echo "$RELEASE_JSON"
        exit 1
    fi

    echo "Uploading $ZIP_NAME..."
    curl -s -X POST \
        -H "Authorization: token $TOKEN" \
        -H "Content-Type: application/zip" \
        "$UPLOAD_URL?name=$ZIP_NAME" \
        --data-binary "@$ZIP_FILE" > /dev/null

    echo "Release v$VERSION published!"
    echo "https://github.com/$REPO/releases/tag/v$VERSION"

else
    echo ""
    echo "No gh CLI or GITHUB_TOKEN found. To publish the release:"
    echo ""
    echo "  Option 1: Set a token and re-run"
    echo "    export GITHUB_TOKEN=ghp_your_token_here"
    echo "    ./release.sh $VERSION"
    echo ""
    echo "  Option 2: Upload manually"
    echo "    https://github.com/$REPO/releases/new"
    echo "    Tag: v$VERSION"
    echo "    Upload: $ZIP_FILE"
fi
