#!/bin/bash
# Builds a sibling app only. Never signs, launches, installs or activates it.
set -euo pipefail
PROBE_SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Build the probe on macOS with Command Line Tools.' >&2
    exit 1
fi
if [[ $# -gt 1 ]]; then echo 'usage: macos/build-probe.sh [output-directory]' >&2; exit 1; fi
PROBE_BUILD_DIR="${1:-$PROBE_SOURCE_DIR/build}"
PROBE_ARCH="$(uname -m)"
case "$PROBE_ARCH" in arm64|x86_64) ;; *) echo 'Unsupported build architecture' >&2; exit 1 ;; esac
mkdir -p "$PROBE_BUILD_DIR"
PROBE_BUILD_DIR="$(cd -- "$PROBE_BUILD_DIR" && pwd)"
PROBE_APP="$PROBE_BUILD_DIR/BlackiceProbe.app"
if [[ -e "$PROBE_APP" || -L "$PROBE_APP" ]]; then
    echo 'Output probe already exists; choose a fresh build directory.' >&2
    exit 1
fi
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_BUILD_DIR/probe-module-cache"
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$PROBE_ARCH-apple-macosx13.0" -swift-version 5 -warnings-as-errors -O \
    -module-cache-path "$PROBE_BUILD_DIR/probe-module-cache" \
    "$PROBE_SOURCE_DIR"/Probe/*.swift -framework Foundation -framework AppKit \
    -o "$PROBE_APP/Contents/MacOS/BlackiceProbe"
cp "$PROBE_SOURCE_DIR/Resources/Probe-Info.plist" "$PROBE_APP/Contents/Info.plist"
plutil -lint "$PROBE_APP/Contents/Info.plist"
echo "Built, unsigned: $PROBE_APP"
echo 'No probe process or window was started; no signing or installation performed.'
