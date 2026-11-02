#!/bin/bash
# Runs the built netshield binary: validate works, a bad file fails with its line,
# and the commands that need the extension refuse with status 69.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
swift build -Xswiftc -warnings-as-errors
BIN="$(swift build --show-bin-path)/netshield"
"$BIN" validate Examples/netshield.toml
bad="$(mktemp)"
trap 'rm -f -- "$bad"' EXIT
printf 'mode = "ask"\nmode = "ask"\n' > "$bad"
set +e
"$BIN" validate "$bad"; status=$?
"$BIN" start; start=$?
"$BIN" approve --app com.example.tool --team ABCDE12345 --host example.com --for 10m; approve=$?
"$BIN" mode sometimes; usage=$?
set -e
[[ $status -eq 65 && $start -eq 69 && $approve -eq 69 && $usage -eq 64 ]] || {
    echo "unexpected exit statuses: validate=$status start=$start approve=$approve usage=$usage" >&2
    exit 1
}
echo "smoke: ok"
