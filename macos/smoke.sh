#!/bin/bash
# Runs the built blackice binary: validate works, a bad file fails with its line, the
# commands that need the signed app or the extension refuse with status 69, start checks its
# configuration before refusing, daemon refuses --config, agent install refuses a binary
# outside Blackice.app, no arguments print the usage, and menu --login refuses outside the app. Also lints the LaunchAgent template and the app's Info.plists and
# entitlements, and checks the app icon.
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
"$BIN" daemon; daemon=$?
"$BIN" daemon --config Examples/blackice.toml; daemon_config=$?
# This build is not inside Blackice.app, so install refuses before it writes anything or runs
# launchctl. agent uninstall is not run here: it would boot out a real agent.
"$BIN" agent install; agent=$?
# Run from a script, not opened by LaunchServices: the usage, not the menu bar app. Turning
# Open at Login on needs the signed app in /Applications, so this build refuses before
# touching anything.
"$BIN" > /dev/null 2>&1; bare=$?
"$BIN" menu --login on; login=$?
"$BIN" menu --login sometimes; login_usage=$?
set -e
[[ $status -eq 65 && $start -eq 69 && $start_bad -eq 65 && $stop -eq 69 && $status_cmd -eq 69 && $mode -eq 69 &&
   $approve -eq 69 && $usage -eq 64 && $daemon -eq 69 && $daemon_config -eq 64 && $agent -eq 69 &&
   $bare -eq 64 && $login -eq 69 && $login_usage -eq 64 ]] || {
    echo "unexpected exit statuses: validate=$status start=$start start_bad=$start_bad stop=$stop" \
        "status=$status_cmd mode=$mode approve=$approve usage=$usage daemon=$daemon daemon_config=$daemon_config" \
        "agent=$agent bare=$bare login=$login login_usage=$login_usage" >&2
    exit 1
}
plutil -lint LaunchAgent/com.valentorassa.blackice.daemon.plist Resources/*.plist Resources/*.entitlements
# macOS refuses to activate a network extension without this key (OSSystemExtensionErrorDomain 9).
plutil -extract NSSystemExtensionUsageDescription raw -o /dev/null Resources/Filter-Info.plist || {
    echo "Resources/Filter-Info.plist lacks NSSystemExtensionUsageDescription" >&2
    exit 1
}
# The app icon that scripts/build-app.sh copies into Blackice.app: CFBundleIconFile names it,
# and the file must be an icns file.
icon="$(plutil -extract CFBundleIconFile raw -o - Resources/Blackice-Info.plist)"
[[ -f "Resources/$icon.icns" && "$(head -c 4 "Resources/$icon.icns")" == icns ]] || {
    echo "Resources/$icon.icns, named by CFBundleIconFile, is missing or not an icns file" >&2
    exit 1
}
echo "smoke: ok"
