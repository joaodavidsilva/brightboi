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
#     relaunch.
#   - Otherwise falls back to ad-hoc signing ("-") for local dev/testing only
#     — not suitable for distribution, and Accessibility/Input Monitoring
#     grants won't persist across relaunches under it. A release build
#     refuses the ad-hoc fallback unless ALLOW_ADHOC_RELEASE=1 is set.
#
# The debug configuration builds a separate "BrightBoi Dev" identity
# (com.ptlghost.BrightBoi.dev) so a local build never shares preferences,
# login items or permission grants with an installed release. The release
# configuration always keeps the shipping identity, com.ptlghost.BrightBoi.
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
PLIST="$APP_DIR/Contents/Info.plist"
BINARY="$APP_DIR/Contents/MacOS/BrightBoi"

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
    # An ad-hoc build has no Team Identifier, so Accessibility and Input
    # Monitoring grants do not carry over between builds. Fine for a local
    # debug build, never for something that gets uploaded.
    if [[ "$CONFIGURATION" == "release" && "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
        echo "error: refusing to ad-hoc sign a release build; set CODESIGN_IDENTITY (or ALLOW_ADHOC_RELEASE=1)." >&2
        exit 1
    fi
    echo "warning: no Developer ID Application or Apple Development identity found — signing ad-hoc for local testing only. Accessibility/Input Monitoring permission grants will not persist across relaunches under ad-hoc signing." >&2
    CODESIGN_IDENTITY="-"
elif [[ "$CODESIGN_IDENTITY" == "-" && "$CONFIGURATION" == "release" && "${ALLOW_ADHOC_RELEASE:-0}" != "1" ]]; then
    echo "error: refusing to ad-hoc sign a release build; set CODESIGN_IDENTITY (or ALLOW_ADHOC_RELEASE=1)." >&2
    exit 1
fi

# Stamp the real SDK into the binary. With the default build system, the
# toolchain records the deployment target (14.0) as the SDK version too,
# and AppKit and SwiftUI then treat the app as a macOS 14-era binary on
# newer systems: pre-26 controls and window chrome. Passing the platform
# version to the linker explicitly records the SDK the app was built
# against. The 14.0 below must stay in sync with `.macOS(.v14)` in
# Package.swift and LSMinimumSystemVersion in Info.plist.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/BrightBoi" "$BINARY"
cp "$ROOT_DIR/Packaging/Info.plist" "$PLIST"
cp "$ROOT_DIR/Packaging/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ "$CONFIGURATION" == "debug" ]]; then
    /usr/libexec/PlistBuddy \
        -c 'Set :CFBundleIdentifier com.ptlghost.BrightBoi.dev' \
        -c 'Set :CFBundleName BrightBoi Dev' \
        -c 'Set :CFBundleDisplayName BrightBoi Dev' \
        "$PLIST"
fi

# Fail the build if the binary did not end up stamped with the SDK we built
# against, which also catches a duplicate or conflicting -platform_version.
stamped_sdk="$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/{f=1} f&&$1=="sdk"{print $2; exit}')"
if [[ "$stamped_sdk" != "$SDK_VERSION" ]]; then
    echo "error: binary stamped with sdk ${stamped_sdk:-none}, expected $SDK_VERSION" >&2
    exit 1
fi

# No --deep: it is deprecated for signing and would apply these options to
# any helper added to the bundle later.
CODESIGN_OPTS=(--force --options runtime --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    CODESIGN_OPTS+=(--timestamp)
fi

codesign "${CODESIGN_OPTS[@]}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# Show who signed it, so an ad-hoc result is obvious.
signature_details="$(codesign -dvv "$APP_DIR" 2>&1)"
while IFS= read -r line; do
    case "$line" in
        Authority=*|TeamIdentifier=*|Signature=*) echo "  $line" ;;
    esac
done <<< "$signature_details"

echo "Built $APP_DIR (signed with: $CODESIGN_IDENTITY)"
