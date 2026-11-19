# Sourced by build-local.sh and make-dmg.sh. Picks the code signing identity and sets:
#   IDENTITY       SHA-1 of the certificate, or "-" for ad hoc
#   IDENTITY_NAME  human-readable name
#   IDENTITY_KIND  developer-id | local | custom | adhoc
_valid=$(/usr/bin/security find-identity -v -p codesigning)
_all=$(/usr/bin/security find-identity -p codesigning)
if [[ -n "${KAPTURE_SIGN_IDENTITY:-}" ]]; then
    IDENTITY=$(awk -v want="$KAPTURE_SIGN_IDENTITY" 'index($0, want) && $2 ~ /^[0-9A-F]{40}$/ {print $2; exit}' <<<"$_all")
    [[ -n "$IDENTITY" ]] || { echo "KAPTURE_SIGN_IDENTITY \"$KAPTURE_SIGN_IDENTITY\" not found in the keychain"; exit 1; }
    IDENTITY_NAME=$(awk -F'"' -v id="$IDENTITY" 'index($0, id) {print $2; exit}' <<<"$_all"); IDENTITY_KIND=custom
    [[ "$IDENTITY_NAME" == "Developer ID Application: "* ]] && IDENTITY_KIND=developer-id
elif IDENTITY=$(awk '/"Developer ID Application: / {print $2; exit}' <<<"$_valid") && [[ -n "$IDENTITY" ]]; then
    IDENTITY_NAME=$(awk -F'"' '/"Developer ID Application: / {print $2; exit}' <<<"$_valid"); IDENTITY_KIND=developer-id
elif IDENTITY=$(awk '/"Kapture Local Signing"/ {print $2; exit}' <<<"$_all") && [[ -n "$IDENTITY" ]]; then
    IDENTITY_NAME="Kapture Local Signing"; IDENTITY_KIND=local
else
    IDENTITY=-; IDENTITY_NAME="ad hoc (Screen Recording must be granted again after every build)"; IDENTITY_KIND=adhoc
fi
unset _valid _all
