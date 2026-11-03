#!/bin/bash
# Builds Blackice.app from the Swift package, unsigned: the blackice CLI is the app's
# executable and the filter is its system extension. Command Line Tools only, no Xcode.
# Nothing is signed, installed or activated; scripts/sign.sh does the signing.
# Layout adapted from blackice-poc macos/build.sh at commit 45a7870.
#
# usage: macos/scripts/build-app.sh OUTPUT_DIR
#   BUILD_NUMBER=N sets CFBundleVersion of both bundles (default 1). macOS replaces an
#   installed extension only with the same or a higher version, so raise it for each
#   rebuilt bundle you install.
set -euo pipefail
MACOS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Build on macOS with the Command Line Tools installed.' >&2
    exit 1
fi
if [[ $# -ne 1 ]]; then
    sed -n 7,10p "$0" >&2
    exit 64
fi
BUILD_NUMBER="${BUILD_NUMBER:-1}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo 'BUILD_NUMBER must be a positive whole number.' >&2
    exit 64
fi
mkdir -p "$1"
OUT="$(cd -- "$1" && pwd)"
APP="$OUT/Blackice.app"
EXT="$APP/Contents/Library/SystemExtensions/com.valentorassa.blackice.filter.systemextension"
# Never leave an old signed bundle or provisioning profile under a fresh build.
if [[ -e "$APP" ]]; then
    echo "$APP already exists; choose a fresh output directory." >&2
    exit 1
fi

for product in blackice blackice-filter; do
    swift build --package-path "$MACOS_DIR" -c release -Xswiftc -warnings-as-errors --product "$product"
done
BIN="$(swift build --package-path "$MACOS_DIR" -c release --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
command cp "$BIN/blackice" "$APP/Contents/MacOS/blackice"
command cp "$BIN/blackice-filter" "$EXT/Contents/MacOS/com.valentorassa.blackice.filter"
command cp "$MACOS_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
command cp "$MACOS_DIR/Resources/Blackice-Info.plist" "$APP/Contents/Info.plist"
command cp "$MACOS_DIR/Resources/Filter-Info.plist" "$EXT/Contents/Info.plist"
BUDDY=/usr/libexec/PlistBuddy
for plist in "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist"; do
    "$BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$plist"
done
plutil -lint "$APP/Contents/Info.plist" "$EXT/Contents/Info.plist" \
    "$MACOS_DIR/Resources/Blackice.entitlements" "$MACOS_DIR/Resources/Filter.entitlements"

# What NetworkExtension and the CLI expect to find.
test "$("$BUDDY" -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.valentorassa.blackice
test "$("$BUDDY" -c 'Print :CFBundleIdentifier' "$EXT/Contents/Info.plist")" = com.valentorassa.blackice.filter
test "$("$BUDDY" -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.filter-data' \
    "$EXT/Contents/Info.plist")" = BlackiceFilterDataProvider
test -x "$APP/Contents/MacOS/blackice"
test -x "$EXT/Contents/MacOS/com.valentorassa.blackice.filter"
test "$("$BUDDY" -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" = AppIcon
test -s "$APP/Contents/Resources/AppIcon.icns"

echo "Built, unsigned: $APP (CFBundleVersion $BUILD_NUMBER, $(uname -m) only)"
echo 'No Developer ID, entitlements or profiles applied; no extension installed or activated.'
