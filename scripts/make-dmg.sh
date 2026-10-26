#!/bin/bash
# Packs build/Silk.app into build/Silk-<VERSION>.dmg, an install image styled like the app icon.
#
#   scripts/make-dmg.sh             (run `make app` first, or use `make dmg`)
#
# The window shows Silk.app and an /Applications link on a background from scripts/make-dmg-background.swift, with
# an arrow from one to the other. The volume carries the app icon.
#
# Finder writes the window layout into the image's .DS_Store, driven by AppleScript, so the first run asks for
# permission to control Finder (System Settings → Privacy & Security → Automation).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if [[ $# -gt 0 ]]; then
    echo "usage: $0" >&2
    exit 2
fi

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$ROOT/build/Silk.app"
DMG="$ROOT/build/Silk-$VERSION.dmg"
VOLUME_NAME=Silk
# Window content size and icon centers; they match the layout in make-dmg-background.swift.
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
APP_POSITION="172, 168"
APPLICATIONS_POSITION="488, 168"

if [[ ! -d "$APP" ]]; then
    echo "error: $APP does not exist; run 'make app' first" >&2
    exit 1
fi

WORK="$(mktemp -d -t silk-dmg)"
MOUNT=""
cleanup() {
    if [[ -n "$MOUNT" ]]; then hdiutil detach -quiet -force "$MOUNT" || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Rendering the background"
swift scripts/make-dmg-background.swift "$WORK/background.png" "$WORK/background@2x.png"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

echo "==> Staging Silk $VERSION"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Silk.app"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/background.tiff" "$STAGE/.background/background.tiff"

# A writable image with room for the .DS_Store Finder is about to write.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk -F '\t' '/\/Volumes\// { print $NF; exit }')"
if [[ -z "$MOUNT" ]]; then
    echo "error: could not mount $WORK/rw.dmg" >&2
    exit 1
fi

echo "==> Laying out the window"
# Addressed by mount point, not by name: an already mounted "Silk" volume mounts this one at "/Volumes/Silk 1".
finder() {
    osascript - "$MOUNT" <<APPLESCRIPT
on run argv
    tell application "Finder"
        set theDisk to disk of (POSIX file (item 1 of argv) as alias)
$1
    end tell
end run
APPLESCRIPT
}
finder "        open theDisk"
# A running Silk tiles the window and Finder would save the tile as the window's size; float it first.
if command -v silk >/dev/null && silk list-windows --all >/dev/null 2>&1; then
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        WINDOW_IDS="$(silk list-windows --all --format '%{window-id}|%{app-bundle-id}|%{window-title}' \
            | awk -F '|' -v title="$VOLUME_NAME" '$2 == "com.apple.finder" && $3 == title { print $1 }')"
        [[ -n "$WINDOW_IDS" ]] && break
        sleep 0.2
    done
    for id in $WINDOW_IDS; do silk layout floating --window-id "$id" || true; done
fi
# The bounds include the title bar, 32 points since macOS 26; the background runs taller for older, shorter ones.
finder "
        set theWindow to container window of theDisk
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set pathbar visible of theWindow to false
        set the bounds of theWindow to {200, 120, 200 + $WINDOW_WIDTH, 120 + $WINDOW_HEIGHT + 32}
        set theOptions to the icon view options of theWindow
        set arrangement of theOptions to not arranged
        set icon size of theOptions to 128
        set text size of theOptions to 13
        set background picture of theOptions to file \".background:background.tiff\" of theDisk
        set position of item \"Silk.app\" of theDisk to {$APP_POSITION}
        set position of item \"Applications\" of theDisk to {$APPLICATIONS_POSITION}
        update theDisk without registering applications
        delay 1
        close theWindow"

# The volume icon and the hidden ".app" are Finder flags; SetFile ships with the Xcode command line tools.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then
    SetFile -a C "$MOUNT"
    SetFile -a E "$MOUNT/Silk.app"
else
    echo "warning: SetFile not found; the volume keeps the generic disk icon and Silk shows as Silk.app" >&2
fi
chmod -Rf go-w "$MOUNT" || true
sync
# Finder may still hold the volume for a moment after closing the window.
for attempt in 1 2 3 4 5; do
    if hdiutil detach -quiet "$MOUNT"; then MOUNT=""; break; fi
    sleep 1
done
if [[ -n "$MOUNT" ]]; then
    hdiutil detach -quiet -force "$MOUNT"
    MOUNT=""
fi

echo "==> Compressing"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"

echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG" | awk -v name="$(basename "$DMG")" '{ print "SHA-256  " $1 "  " name }'
