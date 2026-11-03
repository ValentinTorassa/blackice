#!/bin/bash
# The phase 0 "Done when" check on a real Mac: install the signed Blackice.app, start the
# filter, and show that a small binary signed with our Team ID is blocked under block-all while
# the system curl still reaches the host its rule allows. Then print the filter's log lines and
# roll back. Adapted from the phase 0 draft probar-filtro.sh.
#
# usage: macos/scripts/phase0-test.sh TEAM_ID PATH/Blackice.app
#        macos/scripts/phase0-test.sh --rollback
#   KEEP=1 leaves Blackice.app installed with the filter running in accept-all.
# While block-all is on (well under a minute), apps without a rule lose the network. If the
# script stops in that window, it switches back to accept-all on its way out (Touch ID again).
set -euo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd -- "$SCRIPTS/.." && pwd)"
DEST=/Applications/Blackice.app
BIN="$DEST/Contents/MacOS/blackice"
FILTER_ID=com.valentorassa.blackice.filter
PROBE_ID=com.valentorassa.blackice.probe
HOST=pypi.org
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

rollback() {
    step "Roll back"
    if [[ -x "$BIN" ]]; then
        echo "Touch ID: blackice stop removes the filter and deactivates the extension."
        if ! "$BIN" stop; then
            echo "blackice stop failed; $DEST stays installed. See docs/phase-0.md, Rollback." >&2
            return 1
        fi
        command rm -rf -- "$DEST"
        echo "Removed $DEST"
    else
        echo "$DEST is not installed."
    fi
    systemextensionsctl list | grep -F "$FILTER_ID" || echo "No blackice extension listed."
}

if [[ "${1:-}" == --rollback && $# -eq 1 ]]; then
    rollback
    exit
fi
if [[ $# -ne 2 ]]; then
    sed -n 7,9p "$0" >&2
    exit 64
fi
TEAM_ID=$1 SRC_APP=${2%/}
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die 'TEAM_ID must be 10 upper-case letters or digits'
[[ -d "$SRC_APP" ]] || die "no app at $SRC_APP"
codesign --verify --strict --deep "$SRC_APP" || die "$SRC_APP does not verify; sign it with scripts/sign.sh"
# Capture before grepping: under pipefail, grep -q exits at the first match and the writer's
# SIGPIPE fails the pipeline even though the line is there.
details=$(codesign -dvv "$SRC_APP" 2>&1)
grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" || die "$SRC_APP is not signed by team $TEAM_ID"
# The same build already installed is reused: removing it would uninstall the extension and lose
# a pending or given approval in System Settings. Any other build has to be rolled back first.
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
reuse=
if [[ -e "$DEST" ]]; then
    [[ "$(cdhash "$DEST")" == "$(cdhash "$SRC_APP")" ]] || die "$DEST is another build; run $0 --rollback first"
    reuse=1
fi
IDENTITY=$(security find-identity -v -p codesigning | grep -F 'Developer ID Application:' | grep -F "($TEAM_ID)\"" \
    | awk 'NR == 1 {print $2}')
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity of team $TEAM_ID in the keychain"
W="$MACOS_DIR/build/phase0-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$W"

step "Probe signed with the Team ID, and the network before blackice"
cc -O2 -Wall -o "$W/probe" "$SCRIPTS/probe.c"
codesign --force --sign "$IDENTITY" --identifier "$PROBE_ID" --options runtime --timestamp "$W/probe"
codesign -dvv "$W/probe" 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
"$W/probe" "$HOST" || die "the probe cannot reach $HOST even without blackice; check the network first"

step "Install in /Applications"
if [[ -n "$reuse" ]]; then
    echo "$DEST is this build already; reusing it"
else
    ditto "$SRC_APP" "$DEST"
fi
codesign --verify --strict --deep "$DEST"
echo "Installed $DEST"

step "Configuration: the system curl may reach $HOST; nothing else has a rule"
cat > "$W/blackice.toml" <<EOF
# phase 0 check, written by macos/scripts/phase0-test.sh
mode = "accept-all"

[[allow]]
app = "com.apple.curl"   # Apple platform code: no team
hosts = ["$HOST"]
EOF
"$BIN" validate "$W/blackice.toml"

step "Start: Touch ID, then allow the extension in System Settings"
echo "The first time, open System Settings > General > Login Items & Extensions > Network Extensions"
echo "and turn on Blackice. macOS may also ask to allow the content filter."
"$BIN" start --config "$W/blackice.toml" || die "blackice start failed; run $0 --rollback"
for _ in $(seq 1 30); do
    listed=$(systemextensionsctl list 2>/dev/null) || listed=
    awk -v id="$FILTER_ID" 'index($0, id) && /activated enabled/ {found = 1} END {exit !found}' \
        <<<"$listed" && break
    sleep 2
done
systemextensionsctl list | grep -F "$FILTER_ID" || die "the extension is not listed; run $0 --rollback"
"$BIN" status

# The probe's own message goes to the terminal; the exit status is the result.
run_probe() { if "$W/probe" "$HOST" >&2; then echo 0; else echo $?; fi; }
run_curl() { curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://$HOST/" || true; }

step "accept-all: both reach $HOST"
sleep 2
probe_accept=$(run_probe)
curl_accept=$(run_curl)
echo "probe exit $probe_accept, curl HTTP $curl_accept"

step "block-all: the probe is refused, curl still passes"
echo "Touch ID twice: once for block-all, once to switch back."
restore() {
    echo "Switching back to accept-all."
    "$BIN" mode accept-all || echo "Could not switch back. Run: \"$BIN\" stop (see docs/phase-0.md, Rollback)" >&2
}
trap restore EXIT
"$BIN" mode block-all
sleep 2
probe_block=$(run_probe)
curl_block=$(run_curl)
echo "probe exit $probe_block, curl HTTP $curl_block"
trap - EXIT
restore

step "Filter log (unified logging, last 5 minutes)"
log show --last 5m --style compact --predicate "subsystem == \"$FILTER_ID\"" | tail -40 || true

step "Result"
pass=true
check() { if [[ "$2" == "$3" ]]; then echo "PASS  $1"; else echo "FAIL  $1"; pass=false; fi; }
check "probe connects in accept-all (exit $probe_accept)" "$probe_accept" 0
check "curl reaches $HOST in accept-all (HTTP $curl_accept)" "$curl_accept" 200
check "probe is refused in block-all (exit $probe_block; 2 would mean DNS failed)" "$probe_block" 1
check "curl reaches $HOST in block-all (HTTP $curl_block)" "$curl_block" 200
echo "Work files: $W"

if [[ -n "${KEEP:-}" ]]; then
    echo "KEEP=1: blackice stays installed in accept-all. Roll back later with: $0 --rollback"
else
    rollback
fi
$pass
