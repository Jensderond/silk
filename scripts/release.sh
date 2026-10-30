#!/bin/bash
# Notarizes build/Silk.app and packs the release assets: build/Silk-<VERSION>.zip (what the updater installs) and
# build/Silk-<VERSION>.dmg (the install image).
#
#   scripts/release.sh              (run `make app` first, or use `make release`)
#
# The app must be signed with a Developer ID (scripts/build-app.sh does this for release builds when one is in the
# keychain). Notarization uses the notarytool keychain profile $SILK_NOTARY_PROFILE (default "silk"): an Apple ID,
# app-specific password and team ID of the team the Developer ID belongs to.
#
#   xcrun notarytool store-credentials silk --apple-id <apple id> --team-id <team id>
#
# The app is notarized first and its ticket stapled, so both archives carry an app that opens offline. The DMG is
# then signed, notarized and stapled itself: a downloaded image without a ticket still trips Gatekeeper.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if [[ $# -gt 0 ]]; then
    echo "usage: $0" >&2
    exit 2
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/Silk.app"
ZIP="$ROOT/build/Silk-$VERSION.zip"
DMG="$ROOT/build/Silk-$VERSION.dmg"
PROFILE="${SILK_NOTARY_PROFILE:-silk}"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP does not exist; run 'make app' first" >&2
    exit 1
fi
IDENTITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !found { print $2; found = 1 }')"
if [[ "$IDENTITY" != "Developer ID Application: "* ]]; then
    echo "error: $APP is signed with '${IDENTITY:-ad-hoc}', not a Developer ID; only Developer ID apps can be notarized" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: no notarytool keychain profile '$PROFILE'; create it with" >&2
    echo "       xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id <team id>" >&2
    exit 1
fi

WORK="$(mktemp -d -t silk-release)"
trap 'rm -rf "$WORK"' EXIT

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "==> Notarizing $APP"
# notarytool takes a zip, not a bundle; the ticket is stapled to the app itself.
ditto -c -k --keepParent "$APP" "$WORK/Silk.zip"
notarize "$WORK/Silk.zip"
xcrun stapler staple "$APP"

echo "==> Packing $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

scripts/make-dmg.sh

echo "==> Notarizing $DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> Checking Gatekeeper"
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "==> Release assets for $VERSION"
shasum -a 256 "$ZIP" "$DMG" | awk '{ n = split($2, p, "/"); print "SHA-256  " $1 "  " p[n] }'
