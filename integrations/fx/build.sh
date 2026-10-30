#!/bin/sh
# Builds fx v0.0.16 with the blackice hook patch. Needs git and Zig 0.17.0.
# Usage: integrations/fx/build.sh [WORKDIR]      (default ./fx-blackice)
# Set ZIG_TARGET (for example aarch64-macos) to cross-compile.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${1:-fx-blackice}
fx_commit=481104fdbc247aab4e987e875402dc735e82642e # tag v0.0.16
patch="$here/fx-v0.0.16-blackice-hook.patch"
[ ! -e "$work" ] || { echo "$work already exists; remove it or pass another directory" >&2; exit 1; }
git clone --quiet --depth 1 --branch v0.0.16 https://github.com/vercel-labs/fx "$work"
actual=$(git -C "$work" rev-parse HEAD)
[ "$actual" = "$fx_commit" ] || { echo "fx v0.0.16 is $actual here, expected $fx_commit; stopping" >&2; exit 1; }
git -C "$work" apply --check "$patch"
git -C "$work" apply "$patch"
if [ -n "${ZIG_TARGET:-}" ]; then
    (cd "$work" && zig build -Doptimize=ReleaseSafe -Dtarget="$ZIG_TARGET")
else
    (cd "$work" && zig build -Doptimize=ReleaseSafe)
fi
echo "built $work/zig-out/bin/fx (fx v0.0.16 + blackice hook)"
