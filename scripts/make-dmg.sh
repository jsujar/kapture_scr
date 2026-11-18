#!/bin/bash
# Builds Kapture SCR and packs it into a drag-to-install disk image: dist/Kapture SCR <version>.dmg
# The app is signed with the "Kapture Local Signing" certificate when present (ad hoc otherwise).
# It is not notarized: on another Mac, the first launch needs System Settings › Privacy & Security › Open Anyway.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Kapture SCR"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="$PWD/dist/$NAME $VERSION.dmg"

./scripts/build-local.sh --no-install
APP="$PWD/dist/$NAME.app"

WORK=$(mktemp -d)
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$WORK"
    # Keep only the installed copy visible to Spotlight and the Apps launcher.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
    rm -rf "$APP"
}
trap cleanup EXIT

# Contents: the app, a link to /Applications and the window background.
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
/usr/bin/ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/swift scripts/dmg-background.swift Resources/KaptureLogo.png "$WORK"
/usr/bin/tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# Writable image first, so Finder can store the window layout in it.
RW="$WORK/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -size 64m "$RW"
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF; exit}')

# Window layout (needs permission for Terminal to control Finder; skipped with a warning if denied).
if ! osascript <<EOF
tell application "Finder"
    tell disk "$NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 568}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {170, 215}
        set position of item "Applications" of container window to {490, 215}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "Warning: could not arrange the disk image window (allow Terminal to control Finder in System Settings › Privacy & Security › Automation)."
fi
# Volume icon: the app icon, flagged as a custom icon. Added after the Finder step, which drops it.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || xcrun SetFile -a C "$MOUNT"
sync
hdiutil detach "$MOUNT" -quiet; MOUNT=""

rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

IDENTITY=$(/usr/bin/security find-identity -p codesigning | awk '/"Kapture Local Signing"/ {print $2; exit}')
/usr/bin/codesign --force --sign "${IDENTITY:--}" "$DMG"
hdiutil verify -quiet "$DMG"
printf '\nDisk image: %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1 | xargs)"
