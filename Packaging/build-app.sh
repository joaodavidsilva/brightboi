#!/bin/bash
# Builds BrightBoi and assembles it into a signed BrightBoi.app bundle.
#
# Usage: Packaging/build-app.sh [debug|release]
#
# Signing identity resolution:
#   - CODESIGN_IDENTITY env var, if set, wins.
#   - Otherwise the first installed "Developer ID Application" identity.
#   - Otherwise the first installed "Apple Development" identity — still not
#     suitable for distribution, but (unlike ad-hoc) it carries a real,
#     stable Team Identifier from Apple's CA. macOS's TCC database keys
#     Accessibility/Input Monitoring trust off that identifier, so ad-hoc
#     signing ("no Team Identifier") makes TCC forget the grant on every
#     relaunch — this was confirmed as the F1/F2 key-remap permission bug.
#   - Otherwise falls back to ad-hoc signing ("-") for local dev/testing only
#     — not suitable for distribution, and Accessibility/Input Monitoring
#     grants won't persist across relaunches under it.
#
# Always signs with the hardened runtime (--options runtime): notarization
# requires it, and it's harmless for local test builds too. A real
# Developer ID or Apple Development signature also gets a secure timestamp
# (--timestamp) — notarization rejects signatures without one, and codesign
# refuses the flag outright for ad-hoc signing, hence the conditional. For
# the full notarize-and-package release pipeline, see Packaging/release.sh.
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/.build/BrightBoi.app"

swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/BrightBoi" "$APP_DIR/Contents/MacOS/BrightBoi"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Packaging/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

find_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep "$1" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]+)[[:space:]].*/\1/' || true
}

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(find_identity "Developer ID Application")"
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(find_identity "Apple Development")"
    if [[ -n "$CODESIGN_IDENTITY" ]]; then
        echo "warning: no Developer ID Application identity found — signing with an Apple Development identity for local testing only." >&2
    fi
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "warning: no Developer ID Application or Apple Development identity found — signing ad-hoc for local testing only. Accessibility/Input Monitoring permission grants will not persist across relaunches under ad-hoc signing." >&2
    CODESIGN_IDENTITY="-"
fi

CODESIGN_OPTS=(--force --deep --options runtime --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    CODESIGN_OPTS+=(--timestamp)
fi

codesign "${CODESIGN_OPTS[@]}" "$APP_DIR"

echo "Built $APP_DIR (signed with: $CODESIGN_IDENTITY)"
