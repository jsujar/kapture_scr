#!/bin/bash
# Builds Kapture SCR and packs it into a drag-to-install disk image: dist/Kapture SCR <version>.dmg
# Signed like build-local.sh (see scripts/signing-identity.sh). With a Developer ID certificate the disk
# image is also notarized by Apple and the ticket stapled, so it opens on any Mac without warnings.
# Notarization uses the notarytool keychain profile $KAPTURE_NOTARY_PROFILE (default "kapture-notary"),
# created once with: xcrun notarytool store-credentials kapture-notary --apple-id <id> --team-id <team>
# Without a Developer ID, the first launch on another Mac needs System Settings › Privacy & Security › Open Anyway.
# Apple can take longer than the 30 minute wait, mostly on a new account. The submission keeps going; finish it
# later, without rebuilding, with --finish <submission id>.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/make-dmg.sh [--finish <submission id>]
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARY_PROFILE=${KAPTURE_NOTARY_PROFILE:-kapture-notary}
source scripts/signing-identity.sh
# Fail before the build, not after it, when a release cannot be notarized.
if [[ "$IDENTITY_KIND" == developer-id ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool profile \"$NOTARY_PROFILE\" in the keychain. Create it once with:"
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>"
    exit 1
fi

NAME="Kapture SCR"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="$PWD/dist/$NAME $VERSION.dmg"

# Staples the ticket (when notarized), checks the image and writes the checksums to publish.
# $1: SHA-256 of the app's executable.
finish() {
    if [[ "$IDENTITY_KIND" == developer-id ]]; then
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    else
        echo "Warning: not notarized (no Developer ID Application certificate)."
    fi
    hdiutil verify -quiet "$DMG"
    printf '\nDisk image: %s (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1 | xargs)"
    # Checksums to publish in the release notes; About Kapture SCR shows the app's.
    local dmg_sha; dmg_sha=$(shasum -a 256 "$DMG" | cut -d" " -f1)
    printf 'SHA-256 disk image: %s\nSHA-256 app (Contents/MacOS/Kapture): %s\n' "$dmg_sha" "$1" | tee "${DMG%.dmg}.sha256.txt"
}

# Waits for a submission. Returns 0 when accepted, 2 while Apple is still processing it, 1 when rejected.
wait_notary() {
    local out; out=$(mktemp)
    xcrun notarytool wait "$1" --keychain-profile "$NOTARY_PROFILE" --timeout 30m | tee "$out" || true
    xcrun notarytool info "$1" --keychain-profile "$NOTARY_PROFILE" > "$out" 2>&1 || true
    if grep -q 'status: Accepted' "$out"; then rm -f "$out"; return 0; fi
    if grep -q 'status: In Progress' "$out"; then
        rm -f "$out"
        echo "Apple is still processing submission $1. The disk image is signed but not notarized yet."
        echo "Finish it later, without rebuilding, with:"
        echo "  DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} ./scripts/make-dmg.sh --finish $1"
        return 2
    fi
    cat "$out"; rm -f "$out"
    xcrun notarytool log "$1" --keychain-profile "$NOTARY_PROFILE" || true
    echo "Notarization failed"; return 1
}

if [[ "${1:-}" == "--finish" ]]; then
    [[ -n "${2:-}" && -f "$DMG" ]] || { echo "Usage: $0 --finish <submission id> (needs $DMG)"; exit 1; }
    [[ "$IDENTITY_KIND" == developer-id ]] || { echo "--finish needs the Developer ID certificate"; exit 1; }
    wait_notary "$2" || exit $?
    # The executable's checksum, read from inside the image.
    MOUNT=$(hdiutil attach "$DMG" -readonly -nobrowse -noverify -noautoopen | awk -F'\t' '/\/Volumes\// && !n {print $NF; n=1}')
    EXEC_SHA=$(shasum -a 256 "$MOUNT/$NAME.app/Contents/MacOS/Kapture" | cut -d" " -f1)
    hdiutil detach "$MOUNT" -quiet
    finish "$EXEC_SHA"
    exit 0
fi

./scripts/build-local.sh --no-install
APP="$PWD/dist/$NAME.app"
EXEC_SHA=$(shasum -a 256 "$APP/Contents/MacOS/Kapture" | cut -d" " -f1)

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
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// && !n {print $NF; n=1}')

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

TIMESTAMP=--timestamp=none
[[ "$IDENTITY_KIND" == developer-id ]] && TIMESTAMP=--timestamp
/usr/bin/codesign --force --sign "$IDENTITY" $TIMESTAMP "$DMG"
if [[ "$IDENTITY_KIND" == developer-id ]]; then
    echo "Notarizing (usually a few minutes)…"
    SUBMISSION=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --no-wait | tee /dev/stderr | awk '/^  id: / && !n {print $2; n=1}')
    [[ -n "$SUBMISSION" ]] || { echo "Could not submit to the notary service"; exit 1; }
    wait_notary "$SUBMISSION" || exit $?
fi
finish "$EXEC_SHA"
