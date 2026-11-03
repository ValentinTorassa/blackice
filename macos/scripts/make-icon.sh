#!/bin/bash
# Renders Resources/AppIcon.svg into Resources/AppIcon.icns with the standard sizes: 16, 32,
# 128, 256 and 512 points at 1x and 2x. sips draws the SVG and iconutil packs the set, so it
# runs on macOS with nothing extra installed. Run it after editing AppIcon.svg and commit both
# files; scripts/build-app.sh copies the .icns into Blackice.app.
#
# usage: macos/scripts/make-icon.sh
set -euo pipefail
MACOS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Run on macOS: it needs sips and iconutil.' >&2
    exit 1
fi
if [[ $# -ne 0 ]]; then
    sed -n 7p "$0" >&2
    exit 64
fi
SVG="$MACOS_DIR/Resources/AppIcon.svg"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((points * scale))
        name="icon_${points}x${points}"
        if [[ $scale -eq 2 ]]; then name+='@2x'; fi
        sips -s format png -z "$px" "$px" "$SVG" --out "$iconset/$name.png" > /dev/null
    done
done
iconutil --convert icns --output "$MACOS_DIR/Resources/AppIcon.icns" "$iconset"
echo "Wrote $MACOS_DIR/Resources/AppIcon.icns"
