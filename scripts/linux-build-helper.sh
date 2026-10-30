#!/bin/bash
# Unprivileged build; setup never compiles code as root.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Build as the normal user; root is only needed for the reviewed setup script.' >&2; exit 1; }
cd "$(dirname "$0")/.."
zig_bin=${ZIG:-"$HOME/.local/bin/zig"}
machine=$(/usr/bin/uname -m)
case "$machine" in
    x86_64|aarch64) helper_target="$machine-linux" ;;
    *) printf 'Unsupported Linux helper architecture: %s\n' "$machine" >&2; exit 1 ;;
esac
mkdir -p zig-out/bin
"$zig_bin" build-exe src/linux/helper.zig -target "$helper_target" -mcpu=baseline -O ReleaseSafe -fstrip -femit-bin=zig-out/bin/blackice-linux-helper
printf 'Built zig-out/bin/blackice-linux-helper for %s (baseline CPU). Review linux-setup.sh before installing.\n' "$helper_target"
sha256sum zig-out/bin/blackice-linux-helper
