#!/bin/bash
# Builds BrightBoi and assembles it into a signed BrightBoi.app bundle.
#
# Usage: Packaging/build-app.sh [debug|release]
#
# Signing identity resolution:
#   - CODESIGN_IDENTITY env var, if set, wins.
#   - Otherwise the first installed "Developer ID Application" identity.
#   - Otherwise falls back to ad-hoc signing ("-") for local dev/testing only —
#     not suitable for distribution.
#
# Always signs with the hardened runtime (--options runtime): notarization
# requires it, and it's harmless for local ad-hoc test builds too. For the
# full notarize-and-package release pipeline, see Packaging/release.sh.
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/.build/BrightBoi.app"

swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/BrightBoi" "$APP_DIR/Contents/MacOS/BrightBoi"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]+)[[:space:]].*/\1/' || true)"
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "warning: no Developer ID Application identity found — signing ad-hoc for local testing only." >&2
    CODESIGN_IDENTITY="-"
fi

codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "Built $APP_DIR (signed with: $CODESIGN_IDENTITY)"
