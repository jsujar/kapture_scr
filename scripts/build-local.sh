#!/bin/bash
# Builds Kapture SCR, signs it and installs it to ~/Applications.
# Signing identity, first found wins:
#   1. $KAPTURE_SIGN_IDENTITY (name or SHA-1 of a certificate in the keychain);
#   2. a valid "Developer ID Application" certificate (needed for notarized releases);
#   3. the self-signed "Kapture Local Signing" certificate;
#   4. ad hoc (the Screen Recording permission must then be granted again after every build).
# A stable certificate lets macOS keep the Screen Recording permission across builds.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-local.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required'; exit 1; }
/usr/bin/swift build -c release
BIN=$(/usr/bin/swift build -c release --show-bin-path)/Kapture
APP="$PWD/dist/Kapture SCR.app"
rm -rf "$PWD/dist/Kapture.app"   # pre-rename bundle name
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Kapture"
cp Info.plist "$APP/Contents/Info.plist"
# Where this build came from, shown in About Kapture SCR. "-modified" marks uncommitted changes.
COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD 2>/dev/null || COMMIT="$COMMIT-modified"
/usr/libexec/PlistBuddy -c "Add :KaptureCommit string $COMMIT" -c "Add :KaptureBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP/Contents/Info.plist"
# Translations: Resources/<lang>.lproj/Localizable.strings
rm -rf "$APP/Contents/Resources"; mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# App icon and menu bar template icon
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/KaptureLogo.png "$APP/Contents/Resources/"

source scripts/signing-identity.sh
echo "Signing with $IDENTITY_NAME"
TIMESTAMP=--timestamp=none
[[ "$IDENTITY_KIND" == developer-id ]] && TIMESTAMP=--timestamp   # notarization requires a secure timestamp
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements Kapture.entitlements "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
/usr/bin/codesign -d --entitlements - "$APP"
/usr/bin/codesign -d -r- "$APP" 2>&1 | grep designated
printf '\nBuilt: %s\n' "$APP"

[[ "${1:-}" == "--no-install" ]] && exit 0
DEST="$HOME/Applications/Kapture SCR.app"
LEGACY="$HOME/Applications/Kapture.app"   # same app, installed before the rename
if pgrep -x Kapture >/dev/null; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in 1 2 3 4 5; do pgrep -x Kapture >/dev/null || break; sleep 1; done
    pkill -x Kapture 2>/dev/null || true
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST" "$LEGACY"
/usr/bin/ditto "$APP" "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
# Remove the build copy so Spotlight and the Apps launcher list only the installed app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
rm -rf "$APP"
printf 'Installed: %s\n' "$DEST"
