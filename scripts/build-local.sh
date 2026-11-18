#!/bin/bash
# Builds Kapture SCR, signs it and installs it to ~/Applications.
# Signs with the "Kapture Local Signing" certificate from the login keychain when present, so macOS
# keeps the Screen Recording permission across builds. Otherwise it signs ad hoc
# (the permission must then be granted again after every build).
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
# Translations: Resources/<lang>.lproj/Localizable.strings
rm -rf "$APP/Contents/Resources"; mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# App icon and menu bar template icon
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/KaptureLogo.png "$APP/Contents/Resources/"

IDENTITY=$(/usr/bin/security find-identity -p codesigning | awk '/"Kapture Local Signing"/ {print $2; exit}')
if [[ -n "$IDENTITY" ]]; then
    echo "Signing with Kapture Local Signing ($IDENTITY)"
else
    IDENTITY=-
    echo "Warning: no Kapture Local Signing certificate found; signing ad hoc (Screen Recording must be granted again)."
fi
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime --entitlements Kapture.entitlements "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
/usr/bin/codesign -d --entitlements - "$APP"
/usr/bin/codesign -d -r- "$APP" 2>&1 | grep designated
printf '\nBuilt: %s\n' "$APP"

[[ "${1:-}" == "--no-install" ]] && exit 0
DEST="$HOME/Applications/Kapture SCR.app"
LEGACY="$HOME/Applications/Kapture.app"   # same app, installed before the rename
if pgrep -x Kapture >/dev/null; then
    osascript -e 'tell application id "local.kapture.app" to quit' 2>/dev/null || true
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
