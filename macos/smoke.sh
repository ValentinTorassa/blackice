#!/bin/bash
# Runs the built blackice binary: validate works, a bad file fails with its line, the
# commands that need the signed app or the extension refuse with status 69, and start and
# daemon check their configuration before refusing. Also lints the LaunchAgent template and
# the app's Info.plists and entitlements.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
swift build -Xswiftc -warnings-as-errors
BIN="$(swift build --show-bin-path)/blackice"
"$BIN" validate Examples/blackice.toml
bad="$(mktemp)"
trap 'rm -f -- "$bad"' EXIT
printf 'mode = "ask"\nmode = "ask"\n' > "$bad"
set +e
"$BIN" validate "$bad"; status=$?
# Outside the signed Blackice.app, start/stop/status/mode refuse with 69 (start after
# checking its file).
"$BIN" start --config Examples/blackice.toml; start=$?
"$BIN" start --config "$bad"; start_bad=$?
"$BIN" stop; stop=$?
"$BIN" status; status_cmd=$?
"$BIN" mode block-all; mode=$?
"$BIN" approve --app com.example.tool --team ABCDE12345 --host example.com --for 10m; approve=$?
"$BIN" mode sometimes; usage=$?
"$BIN" daemon --config Examples/blackice.toml; daemon=$?
"$BIN" daemon --config "$bad"; daemon_bad=$?
set -e
[[ $status -eq 65 && $start -eq 69 && $start_bad -eq 65 && $stop -eq 69 && $status_cmd -eq 69 && $mode -eq 69 &&
   $approve -eq 69 && $usage -eq 64 && $daemon -eq 69 && $daemon_bad -eq 65 ]] || {
    echo "unexpected exit statuses: validate=$status start=$start start_bad=$start_bad stop=$stop" \
        "status=$status_cmd mode=$mode approve=$approve usage=$usage daemon=$daemon daemon_bad=$daemon_bad" >&2
    exit 1
}
plutil -lint LaunchAgent/com.valentorassa.blackice.daemon.plist Resources/*.plist Resources/*.entitlements
# macOS refuses to activate a network extension without this key (OSSystemExtensionErrorDomain 9).
plutil -extract NSSystemExtensionUsageDescription raw -o /dev/null Resources/Filter-Info.plist || {
    echo "Resources/Filter-Info.plist lacks NSSystemExtensionUsageDescription" >&2
    exit 1
}
echo "smoke: ok"
