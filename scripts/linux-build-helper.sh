#!/bin/bash
# Unprivileged build; setup never compiles code as root.
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Build as the normal user; root is only needed for the reviewed setup script.' >&2; exit 1; }
cd "$(dirname "$0")/.."
zig_bin=${ZIG:-"$HOME/.local/bin/zig"}
mkdir -p zig-out/bin
"$zig_bin" build-exe src/linux/helper.zig -O ReleaseSafe -fstrip -femit-bin=zig-out/bin/blackice-linux-helper
printf '%s\n' 'Built zig-out/bin/blackice-linux-helper. Review linux-setup.sh before installing.'
sha256sum zig-out/bin/blackice-linux-helper
