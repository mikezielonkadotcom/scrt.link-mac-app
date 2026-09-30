#!/bin/bash
# Archive an app bundle for notarization and GitHub Releases.
#
# --norsrc keeps extended attributes (macOS adds com.apple.provenance to
# built files) out of the ZIP. Without it, ditto stores them as AppleDouble
# "._*" entries, and unzip-based extractors, including the in-app updater in
# 1.6.0 and earlier, write those into the bundle as extra files that break
# its signature seal. A stapled ticket is the regular file
# Contents/CodeResources, so it is kept.
#
# Usage: ./package.sh <path/to/App.app> <output.zip>

set -euo pipefail

APP_BUNDLE="${1:?Usage: ./package.sh <path/to/App.app> <output.zip>}"
ZIP_FILE="${2:?Usage: ./package.sh <path/to/App.app> <output.zip>}"

rm -f "$ZIP_FILE"
ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ZIP_FILE"
