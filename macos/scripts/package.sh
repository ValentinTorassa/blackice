#!/bin/bash
# Packages a signed Blackice.app for release: notarizes and staples a copy unless sign.sh already
# did, zips it with ditto as Blackice-<version>.zip, writes the zip's SHA-256, and then checks the
# result the way a person who downloads it would: the checksum, and on the unpacked app its
# signature, its stapled ticket and Gatekeeper's assessment. Never installs or activates anything.
# A zip rather than a .dmg or .pkg: a .pkg needs a Developer ID Installer certificate, and the
# ticket that matters is the one stapled to the app, which macOS checks when it activates the
# extension.
#
# usage: macos/scripts/package.sh TEAM_ID PATH/Blackice.app [NOTARY_PROFILE]
#   PATH/Blackice.app: the app from scripts/sign.sh. NOTARY_PROFILE: a notarytool keychain profile,
#   needed only when the app is not notarized and stapled yet. NOTARY_KEYCHAIN=PATH as in sign.sh.
#   DRY=1 macos/scripts/package.sh TEAM_ID PATH/Blackice.app  packages the ad hoc app from
#   DRY=1 scripts/sign.sh: no notarization, no stapling, no Gatekeeper and no Developer ID checks.
#   It checks this script, the archive, the checksum file and the unpacked app's signature.
#   OUT=DIR writes to DIR (default macos/build/package-<time>).
set -euo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd -- "$SCRIPTS/.." && pwd)"
HOST_ID=com.valentorassa.blackice
FILTER_ID=com.valentorassa.blackice.filter
BUDDY=/usr/libexec/PlistBuddy
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

if [[ $# -lt 2 || $# -gt 3 ]]; then
    sed -n 10,16p "$0" >&2
    exit 64
fi
TEAM_ID=$1 SRC_APP=${2%/} NOTARY=${3:-}
DRY=${DRY:-}
[[ "$(uname -s)" == Darwin ]] || die 'run this on macOS'
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die 'TEAM_ID must be 10 upper-case letters or digits'
[[ -d "$SRC_APP" && "$(basename -- "$SRC_APP")" == Blackice.app ]] || die "no Blackice.app at $SRC_APP"
OUT="${OUT:-$MACOS_DIR/build/package-$(date +%Y%m%d-%H%M%S)}"
[[ -e "$OUT" ]] && die "$OUT already exists; choose a fresh directory"
mkdir -p "$OUT"
OUT="$(cd -- "$OUT" && pwd)"
EXT_PATH=Contents/Library/SystemExtensions/$FILTER_ID.systemextension

plist() { "$BUDDY" -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

# Signature checks for one bundle: identifier, hardened runtime and, unless DRY, the Developer ID
# of TEAM_ID with a secure timestamp.
check_signature() {
    local bundle=$1 id=$2 details
    details=$(codesign -dvv "$bundle" 2>&1)
    grep -qx "Identifier=$id" <<<"$details" || die "$bundle is not signed as $id"
    grep -q 'flags=.*runtime' <<<"$details" || die "$bundle is not signed with the hardened runtime"
    if [[ -z "$DRY" ]]; then
        grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" || die "$bundle is not signed by team $TEAM_ID"
        grep -q '^Authority=Developer ID Application:' <<<"$details" || die "$bundle is not signed with a Developer ID Application certificate"
        grep -q '^Timestamp=' <<<"$details" || die "$bundle has no secure timestamp"
    fi
    grep -E '^(Identifier|TeamIdentifier|Timestamp)=' <<<"$details" | sed 's/^/  /'
}

step "The app"
VERSION=$(plist "$SRC_APP" CFBundleShortVersionString)
BUILD=$(plist "$SRC_APP" CFBundleVersion)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString '$VERSION' is not a version like 0.1.0"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "CFBundleVersion '$BUILD' is not a positive whole number"
[[ "$(plist "$SRC_APP/$EXT_PATH" CFBundleShortVersionString)" == "$VERSION" ]] || die "the extension's version differs from the app's"
[[ "$(plist "$SRC_APP/$EXT_PATH" CFBundleVersion)" == "$BUILD" ]] || die "the extension's build number differs from the app's"
# Each build's own XPC service, as sign.sh names it and the CLI looks it up.
SERVICE=$(plist "$SRC_APP/$EXT_PATH" NetworkExtension:NEMachServiceName)
[[ "$SERVICE" == "$TEAM_ID.$FILTER_ID.$BUILD" ]] || die "NEMachServiceName is '$SERVICE', not $TEAM_ID.$FILTER_ID.$BUILD"
NAME="Blackice-$VERSION"
echo "Blackice.app $VERSION (build $BUILD) -> $OUT/$NAME.zip"
codesign --verify --strict --deep --verbose=2 "$SRC_APP"
echo "$FILTER_ID:"
check_signature "$SRC_APP/$EXT_PATH" "$FILTER_ID"
echo "$HOST_ID:"
check_signature "$SRC_APP" "$HOST_ID"

# Work on a copy, so stapling never touches the input.
mkdir -p "$OUT/stage"
ditto "$SRC_APP" "$OUT/stage/Blackice.app"
APP="$OUT/stage/Blackice.app"

if [[ -n "$DRY" ]]; then
    step "Notarize and staple: skipped (DRY)"
    echo "DRY run: ad hoc signature, no notarization. The package cannot activate the extension."
elif xcrun stapler validate "$APP" > /dev/null 2>&1; then
    step "Notarize and staple: done already"
    echo "The app has a stapled ticket (sign.sh notarized it)."
else
    step "Notarize and staple"
    [[ -n "$NOTARY" ]] || die "the app is not notarized and stapled; pass a NOTARY_PROFILE"
    mkdir -p "$OUT/notary"
    ditto -c -k --keepParent "$APP" "$OUT/notary/Blackice.zip"
    notary=(--keychain-profile "$NOTARY")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then notary+=(--keychain "$NOTARY_KEYCHAIN"); fi
    xcrun notarytool submit "$OUT/notary/Blackice.zip" "${notary[@]}" --wait --output-format json \
        > "$OUT/notary/submit.json" || true
    status=$(plutil -extract status raw -o - "$OUT/notary/submit.json" 2>/dev/null) || status=
    id=$(plutil -extract id raw -o - "$OUT/notary/submit.json" 2>/dev/null) || id=
    [[ "$status" == Accepted ]] || die "notarization ended '${status:-without a status}'; see: xcrun notarytool log ${id:-<id>} ${notary[*]}"
    echo "Accepted: submission $id"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

step "Archive and checksum"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
(cd -- "$OUT" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
cat "$OUT/$NAME.zip.sha256"

step "Check the package as a download"
(cd -- "$OUT" && shasum -a 256 -c "$NAME.zip.sha256")
mkdir -p "$OUT/verify"
ditto -x -k "$OUT/$NAME.zip" "$OUT/verify"
entries=$(ls -A "$OUT/verify")
[[ "$entries" == Blackice.app ]] || die "the archive should hold only Blackice.app; it holds: $entries"
UNPACKED="$OUT/verify/Blackice.app"
codesign --verify --strict --deep --verbose=2 "$UNPACKED"
check_signature "$UNPACKED/$EXT_PATH" "$FILTER_ID" > /dev/null
check_signature "$UNPACKED" "$HOST_ID" > /dev/null
for part in "" "/$EXT_PATH"; do
    [[ "$(cdhash "$UNPACKED$part")" == "$(cdhash "$SRC_APP$part")" ]] || die "the unpacked ${part:-app} differs from the input (CDHash)"
done
echo "The unpacked app and its extension have the input's CDHashes."
if [[ -z "$DRY" ]]; then
    xcrun stapler validate "$UNPACKED"
    # spctl -t install assesses installer packages; for an app inside a zip the assessment is
    # the app's own, as Gatekeeper makes it when the app first runs.
    assessment=$(spctl --assess --type execute -vv "$UNPACKED" 2>&1) || die "Gatekeeper rejects the app: $assessment"
    echo "$assessment"
    grep -q 'source=Notarized Developer ID' <<<"$assessment" || die "Gatekeeper does not see a notarized Developer ID app"
fi
command rm -rf -- "$OUT/verify"

step "Done: $OUT/$NAME.zip"
ls -l "$OUT/$NAME.zip" "$OUT/$NAME.zip.sha256"
if [[ -n "$DRY" ]]; then
    echo 'DRY run finished. Ad hoc signature: this package is for checking the script, not for release.'
else
    echo "Publish both files together; docs/install.md says how to check and install them."
fi
