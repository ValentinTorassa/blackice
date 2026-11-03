#!/bin/bash
# Builds Netshield.app fresh and signs it with the Developer ID: checks both provisioning
# profiles, signs the extension first and then the app with the hardened runtime and a secure
# timestamp, verifies, and notarizes when given a notarytool profile. Never installs or
# activates anything. Adapted from the phase 0 draft ~/netshield-fase0/firmar-blackice.sh and
# blackice macos/signing-copies.sh at commit 45a7870.
#
# usage: macos/scripts/sign.sh TEAM_ID APP_PROFILE FILTER_PROFILE [NOTARY_PROFILE]
#   APP_PROFILE, FILTER_PROFILE: Developer ID provisioning profiles for com.valentorassa.netshield
#   and com.valentorassa.netshield.filter. NOTARY_PROFILE: a notarytool keychain profile name.
#   DRY=1 macos/scripts/sign.sh TEAM_ID - -  signs ad hoc without profiles. It checks this
#   script, the bundle layout and the entitlements; the result cannot activate the extension.
#   OUT=DIR builds in DIR (default macos/build/sign-<time>). BUILD_NUMBER as in build-app.sh.
set -euo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd -- "$SCRIPTS/.." && pwd)"
HOST_ID=com.valentorassa.netshield
FILTER_ID=com.valentorassa.netshield.filter
BUDDY=/usr/libexec/PlistBuddy
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

if [[ $# -lt 3 || $# -gt 4 ]]; then
    sed -n 8,13p "$0" >&2
    exit 64
fi
TEAM_ID=$1 APP_PROFILE=$2 FILTER_PROFILE=$3 NOTARY=${4:-}
DRY=${DRY:-}
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die 'TEAM_ID must be 10 upper-case letters or digits'
OUT="${OUT:-$MACOS_DIR/build/sign-$(date +%Y%m%d-%H%M%S)}"
[[ -e "$OUT" ]] && die "$OUT already exists; choose a fresh directory"
mkdir -p "$OUT/signing"
OUT="$(cd -- "$OUT" && pwd)"
APP_GROUP="$TEAM_ID.$HOST_ID"
MACH_SERVICE="$APP_GROUP.filter"

# A Developer ID profile for this team and App ID, with the content filter entitlement and not
# expired. Decoded into $4.
check_profile() {
    local kind=$1 file=$2 bundle=$3 plist=$4 team appid ne expiry now
    [[ -r "$file" ]] || die "cannot read the $kind profile: $file"
    security cms -D -i "$file" > "$plist" 2>/dev/null || die "the $kind profile is not a provisioning profile: $file"
    team=$("$BUDDY" -c 'Print :Entitlements:com.apple.developer.team-identifier' "$plist" 2>/dev/null) || team=
    [[ "$team" == "$TEAM_ID" ]] || die "the $kind profile is for team '$team', not $TEAM_ID"
    appid=$("$BUDDY" -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null) || appid=
    [[ "$appid" == "$TEAM_ID.$bundle" ]] || die "the $kind profile is for App ID '$appid', not $TEAM_ID.$bundle"
    ne=$("$BUDDY" -c 'Print :Entitlements:com.apple.developer.networking.networkextension' "$plist" 2>/dev/null) || ne=
    grep -qx '[[:space:]]*content-filter-provider-systemextension' <<<"$ne" \
        || die "the $kind profile lacks content-filter-provider-systemextension (Network Extensions on the App ID)"
    [[ "$("$BUDDY" -c 'Print :ProvisionsAllDevices' "$plist" 2>/dev/null)" == true ]] \
        || die "the $kind profile is not a Developer ID profile (ProvisionsAllDevices is not set)"
    expiry=$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null) || die "the $kind profile has no expiration date"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [[ "$expiry" > "$now" ]] || die "the $kind profile expired on $expiry"
    echo "$kind profile: App ID $appid, Developer ID, expires $expiry"
}

# SHA-1 of each certificate a decoded profile allows, upper-case hex, one per line.
profile_certificates() {
    /usr/bin/python3 -I -c '
import hashlib, plistlib, sys
with open(sys.argv[1], "rb") as f:
    for der in plistlib.load(f).get("DeveloperCertificates", []):
        print(hashlib.sha1(der).hexdigest().upper())' "$1"
}

if [[ -n "$DRY" ]]; then
    IDENTITY=-
    TIMESTAMP=--timestamp=none
    echo "DRY run: ad hoc signature, no profiles, no notarization. The result cannot activate the extension."
else
    step "Check the provisioning profiles"
    check_profile app "$APP_PROFILE" "$HOST_ID" "$OUT/signing/app-profile.plist"
    check_profile filter "$FILTER_PROFILE" "$FILTER_ID" "$OUT/signing/filter-profile.plist"
    [[ "$("$BUDDY" -c 'Print :Entitlements:com.apple.developer.system-extension.install' "$OUT/signing/app-profile.plist" 2>/dev/null)" == true ]] \
        || die 'the app profile lacks com.apple.developer.system-extension.install (System Extension on the App ID)'

    step "Find the Developer ID Application identity both profiles name"
    profile_certificates "$OUT/signing/app-profile.plist" > "$OUT/signing/app-certs.txt"
    profile_certificates "$OUT/signing/filter-profile.plist" > "$OUT/signing/filter-certs.txt"
    IDENTITY=
    while read -r hash; do
        if grep -qx "$hash" "$OUT/signing/app-certs.txt" && grep -qx "$hash" "$OUT/signing/filter-certs.txt"; then
            IDENTITY=$hash
            break
        fi
    done < <(security find-identity -v -p codesigning | grep -F 'Developer ID Application:' | grep -F "($TEAM_ID)\"" | awk '{print $2}')
    [[ -n "$IDENTITY" ]] || die "no Developer ID Application identity of team $TEAM_ID in the keychain is in both profiles"
    security find-identity -v -p codesigning | grep -F "$IDENTITY"
    TIMESTAMP=--timestamp
fi

step "Build"
"$SCRIPTS/build-app.sh" "$OUT"
APP="$OUT/Netshield.app"
EXT="$APP/Contents/Library/SystemExtensions/$FILTER_ID.systemextension"

step "Fill in the Team ID: NEMachServiceName, app group, application identifiers"
command cp "$MACOS_DIR/Resources/Netshield.entitlements" "$OUT/signing/Netshield.entitlements"
command cp "$MACOS_DIR/Resources/Filter.entitlements" "$OUT/signing/Filter.entitlements"
"$BUDDY" -c "Set :NetworkExtension:NEMachServiceName $MACH_SERVICE" "$EXT/Contents/Info.plist"
"$BUDDY" -c "Set :com.apple.security.application-groups:0 $APP_GROUP" "$OUT/signing/Filter.entitlements"
for pair in "Netshield:$HOST_ID" "Filter:$FILTER_ID"; do
    "$BUDDY" -c "Add :com.apple.application-identifier string $TEAM_ID.${pair#*:}" \
        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$OUT/signing/${pair%%:*}.entitlements"
done
for file in "$EXT/Contents/Info.plist" "$OUT/signing/Netshield.entitlements" "$OUT/signing/Filter.entitlements"; do
    if grep -q 'TEAM_ID\.' "$file"; then die "a TEAM_ID placeholder is left in $file"; fi
done
plutil -lint "$EXT/Contents/Info.plist" "$OUT/signing/Netshield.entitlements" "$OUT/signing/Filter.entitlements"
echo "NEMachServiceName $MACH_SERVICE; app group $APP_GROUP (extension)"

if [[ -z "$DRY" ]]; then
    command cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
    command cp "$FILTER_PROFILE" "$EXT/Contents/embedded.provisionprofile"
    echo "Embedded both provisioning profiles"
fi

step "Sign the extension, then the app (hardened runtime)"
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" \
    --entitlements "$OUT/signing/Filter.entitlements" "$EXT"
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" \
    --entitlements "$OUT/signing/Netshield.entitlements" "$APP"

step "Verify"
codesign --verify --strict --deep --verbose=2 "$APP"
for pair in "$EXT:$FILTER_ID" "$APP:$HOST_ID"; do
    bundle=${pair%:*} id=${pair##*:}
    details=$(codesign -dvv "$bundle" 2>&1)
    grep -qx "Identifier=$id" <<<"$details" || die "$bundle is not signed as $id"
    grep -q 'flags=.*runtime' <<<"$details" || die "$bundle is not signed with the hardened runtime"
    if [[ -z "$DRY" ]]; then
        grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" || die "$bundle is not signed by team $TEAM_ID"
        grep -q '^Timestamp=' <<<"$details" || die "$bundle has no secure timestamp"
    fi
    echo "$id:"
    grep -E '^(Identifier|TeamIdentifier|Authority|Timestamp|CodeDirectory)' <<<"$details" | sed 's/^/  /'
    codesign -d --entitlements - --xml "$bundle" 2>/dev/null | plutil -p - | sed 's/^/  /'
done

if [[ -n "$NOTARY" && -z "$DRY" ]]; then
    step "Notarize and staple"
    ditto -c -k --keepParent "$APP" "$OUT/Netshield.zip"
    xcrun notarytool submit "$OUT/Netshield.zip" --keychain-profile "$NOTARY" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute -vv "$APP"
fi

step "Done: $APP"
if [[ -n "$DRY" ]]; then
    echo 'DRY run finished. Ad hoc signature: macOS will not activate this extension.'
else
    echo "Next: macos/scripts/phase0-test.sh $TEAM_ID \"$APP\""
fi
