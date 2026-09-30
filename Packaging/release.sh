#!/bin/bash
# Produces the final shippable artifact: a Developer-ID-signed, notarized,
# stapled BrightBoi.app packaged into a distributable .zip. BrightBoi ships
# directly rather than through the Mac App Store, because it uses private
# APIs the App Store disallows.
#
# Usage: NOTARY_PROFILE=<profile-name> Packaging/release.sh
#
# Run it from a clean checkout of a tag named v<CFBundleShortVersionString>.
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
ZIP_PATH="$DIST_DIR/BrightBoi-$VERSION.zip"

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a profile created via 'xcrun notarytool store-credentials'}"

# A release is built from a tagged, unmodified tree, so the published binary
# can always be traced back to its source.
tag="$(git -C "$ROOT_DIR" describe --exact-match --tags HEAD 2>/dev/null || true)"
if [[ "$tag" != "v$VERSION" ]]; then
    echo "error: HEAD must be tagged v$VERSION (found: ${tag:-no tag}). Tag the release commit first." >&2
    exit 1
fi
if ! git -C "$ROOT_DIR" diff --quiet HEAD; then
    echo "error: the working tree has uncommitted changes; release from a clean checkout." >&2
    exit 1
fi

"$ROOT_DIR/Packaging/build-app.sh" release

# The shipping identity must never be the debug one.
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_id" != "com.ptlghost.BrightBoi" ]]; then
    echo "error: built app has bundle identifier '$bundle_id', expected com.ptlghost.BrightBoi." >&2
    exit 1
fi

# A notarized release can't be ad-hoc or development signed — fail fast with
# a clear reason rather than letting the notary submission reject it later.
"$ROOT_DIR/Packaging/check-developer-id.sh" "$APP_DIR"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Apple's documented submission format: a zip made with ditto (preserves the
# bundle structure and resource forks; a plain zip(1) archive can corrupt
# app bundles in ways notarization silently rejects).
echo "Submitting $APP_DIR for notarization (profile: $NOTARY_PROFILE)..."
ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
submit_json=""
if ! submit_json="$(xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"; then
    echo "$submit_json" >&2
    echo "error: notarytool submit failed." >&2
    submission_id="$(printf '%s' "$submit_json" | plutil -extract id raw -o - - 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
fi
submission_id="$(printf '%s' "$submit_json" | plutil -extract id raw -o - -)"
status="$(printf '%s' "$submit_json" | plutil -extract status raw -o - -)"
if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization finished with status '$status' (submission $submission_id). Log:" >&2
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi
rm -f "$NOTARIZE_ZIP"

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_DIR"

echo "Verifying Gatekeeper acceptance..."
spctl --assess --type execute -v "$APP_DIR"

# --norsrc and --noextattr keep AppleDouble (._) entries out of the archive,
# which would otherwise break the signature when unzipped with other tools.
echo "Packaging $ZIP_PATH..."
ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" "$ZIP_PATH"

# Verify the archive the way a user gets it: unzipped with the system tool
# into a fresh directory.
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT
/usr/bin/unzip -q "$ZIP_PATH" -d "$verify_dir"
codesign --verify --deep --strict "$verify_dir/BrightBoi.app"
spctl --assess --type execute -v "$verify_dir/BrightBoi.app"

(cd "$DIST_DIR" && shasum -a 256 "BrightBoi-$VERSION.zip" > "BrightBoi-$VERSION.zip.sha256")

echo "Release artifact ready: $ZIP_PATH"
echo "Checksum: $ZIP_PATH.sha256"
echo "Publish with: gh release create v$VERSION '$ZIP_PATH' '$ZIP_PATH.sha256' --verify-tag --notes-file <notes.md>"
