#!/bin/bash
# Produces the final shippable artifact: a Developer-ID-signed, notarized,
# stapled BrightBoi.app packaged into a distributable .dmg — per ADR-0001
# (direct distribution outside the Mac App Store, since the app depends on
# private APIs the App Store disallows).
#
# Usage: NOTARY_PROFILE=<profile-name> Packaging/release.sh
#
# One-time setup this script assumes is already done on the machine running
# it (real Apple Developer credentials — deliberately not scripted or
# committed to the repo):
#   - A "Developer ID Application" certificate installed in the login
#     keychain. Verify with: security find-identity -v -p codesigning
#   - Notary credentials stored under a named keychain profile:
#       xcrun notarytool store-credentials "<profile-name>" \
#           --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#     (or the --key/--key-id/--issuer form for an App Store Connect API key).
#     Pass that profile name in via NOTARY_PROFILE.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/BrightBoi.app"
DIST_DIR="$ROOT_DIR/.build/dist"
NOTARIZE_ZIP="$DIST_DIR/BrightBoi-notarize.zip"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Packaging/Info.plist")"
DMG_PATH="$DIST_DIR/BrightBoi-$VERSION.dmg"

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a profile created via 'xcrun notarytool store-credentials'}"

"$ROOT_DIR/Packaging/build-app.sh" release

# A notarized release can't be ad-hoc signed — fail fast with a clear reason
# rather than letting the notary submission reject it later.
if ! codesign -dv "$APP_DIR" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "error: $APP_DIR is not signed with a Developer ID Application certificate." >&2
    echo "Install one, or set CODESIGN_IDENTITY to select it, then re-run." >&2
    exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Apple's documented submission format: a zip made with ditto (preserves the
# bundle structure and resource forks; a plain zip(1) archive can corrupt
# app bundles in ways notarization silently rejects).
echo "Submitting $APP_DIR for notarization (profile: $NOTARY_PROFILE)..."
ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$NOTARIZE_ZIP"

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_DIR"

echo "Verifying Gatekeeper acceptance..."
spctl --assess --type execute -v "$APP_DIR"

echo "Packaging $DMG_PATH..."
hdiutil create -volname "BrightBoi" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"

echo "Release artifact ready: $DMG_PATH"
