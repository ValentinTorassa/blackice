#!/usr/bin/env bash
# blackice grant expiry: a connection opened under an owner grant is cut when the grant ends, and a new
# connection after that is refused again. Linux (with the helper installed) and macOS.
#
# The stream is server-paced: httpbingo.org's /drip sends its bytes evenly over the time asked for, and curl -N
# reads each byte as it arrives. So nothing waits unread in curl's own receive buffer, and the byte count shows
# when the flow stops. (Bytes already in a client's buffer stay readable after a reset; a slow reader would hide
# the cut.) /drip allows at most 10 s per request, so curl asks for six in a row on one connection.
#
# The scoped command waits on its stdin for the owner's go-ahead. The owner (this script, outside the scope)
# grants httpbingo.org for 20 s, then writes one line. Needs network access to httpbingo.org. Synthetic policy,
# no credentials. Never installs anything, never uses sudo.
#
# Usage: scripts/e2e/grant-expiry.sh      (BLACKICE=/path/to/blackice, E2E_DIR=/path/to/empty/dir optional)
set -u
. "$(dirname "$0")/lib.sh"

case "$(uname -s)" in
    Linux)
        HELPER=/usr/local/libexec/blackice-linux-helper
        [ -e "$HELPER" ] || die "the Linux helper is not installed at $HELPER (the owner runs scripts/linux-setup.sh)"
        ;;
    Darwin) HELPER= ;;
    *) die "this script is for Linux and macOS" ;;
esac
command -v python3 > /dev/null || die "python3 is needed (receipt checks)"
command -v curl > /dev/null || die "curl is needed"
e2e_blackice
e2e_workdir
e2e_policy
HOST=httpbingo.org
GRANT_SECONDS=20

if [ -n "$HELPER" ]; then
    . /etc/os-release 2> /dev/null
    echo "== Linux $(uname -r) ($(uname -m)), ${PRETTY_NAME:-unknown distribution}"
    echo "== $("$B" version); helper $(ls -l "$HELPER" | awk '{print $1, $3, $4}')"
else
    echo "== macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), SIP: $(csrutil status 2> /dev/null | sed 's/.*: //')"
    echo "== $("$B" version)"
fi
echo "== blackice sha256 $( (sha256sum "$B" 2> /dev/null || shasum -a 256 "$B") | cut -d' ' -f1)"
echo "== work dir $W"

# The backend must start a scope here; otherwise nothing below means anything.
scoped probe -- /usr/bin/true
[ "$RC" -eq 0 ] && [ -n "$SID" ] || die "blackice run could not start a scope here (exit $RC); see $ERR"

INNER='
host=$2
code() { curl -sS -o /dev/null -m 15 -w "%{http_connect}/%{http_code}" "$1" 2> /dev/null; }
now() { date -u +%H:%M:%SZ; }
body() { grep -v "^  \[transfer done" "$1.out" | tr -d "\n" | wc -c | tr -d " "; }
echo "inside: $(now) waiting for the owner grant"
read -r _
echo "inside: $(now) $host right after the grant -> $(code "https://$host/get")"
echo "inside: $(now) stream: six 10 s drips of 1000 bytes on one connection (100 bytes/s for 60 s); bytes so far, every 2 s:"
D="https://$host/drip?duration=10&numbytes=1000&delay=0"
start=$(date +%s)
curl -sS -N --fail-early -m 90 -w "\n  [transfer done: HTTP %{http_code}, new connections %{num_connects}]\n" "$D" "$D" "$D" "$D" "$D" "$D" > "$1.out" 2> "$1.err" &
c=$!
while kill -0 $c 2> /dev/null; do echo "  sample $(now) $(body "$1") bytes"; sleep 2; done
wait $c
rc=$?
echo "inside: $(now) stream curl exit $rc after $(body "$1") bytes in $(( $(date +%s) - start )) s: $(cat "$1.err")"
grep "^  \[transfer done" "$1.out"
echo "inside: $(now) $host again, a new connection -> $(code "https://$host/get")"
'

LOG="$W/out/expiry-run.log"
OWNER="$W/out/owner.txt"
: > "$LOG"
# The owner: waits for the scope to ask, grants from outside, then lets the scope go on.
owner() {
    local i sid
    for i in $(seq 1 240); do
        grep -q "inside: .* waiting for the owner grant" "$LOG" 2> /dev/null && break
        sleep 0.25
    done
    sid=$(sed -n 's/^blackice: scope \(s-[0-9a-f]*\) .*/\1/p' "$LOG" | head -1)
    {
        echo "outside: $(date -u +%H:%M:%SZ) \$ blackice grant $sid $HOST --for ${GRANT_SECONDS}s"
        "$B" grant "$sid" "$HOST" --for "${GRANT_SECONDS}s"
        echo "outside: grant exit $?"
    } > "$OWNER" 2>&1
    echo go
}
echo
echo "\$ blackice run --policy agent.json -- /bin/bash -c INNER inner ./stream $HOST   (stdin: the owner's go-ahead)"
# Through pipes, not straight into files: some builds write their own lines at fixed file offsets.
owner | "$B" run --policy "$POLICY" -- /bin/bash -c "$INNER" inner "$W/stream" "$HOST" 2>&1 | cat > "$LOG"
RC=${PIPESTATUS[1]}
echo
echo "== owner, outside the scope"
sed 's/^/  | /' "$OWNER"
echo "== scoped command output"
sed 's/^/  | /' "$LOG"
echo "  [run exit $RC]"
echo
scope_of "$LOG" || die "no scope line in the run's output"

# The receipt of the expiry must come within 1 s of the grant's end (the watchdog wakes at least every 200 ms).
expiry_on_time() {
    python3 -I - "$RCPT" <<'PY'
import datetime, json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
def ts(s):
    return datetime.datetime.strptime(s.replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S.%f%z")
grant = [r for r in rows if r.get("event") == "grant" and r.get("reason") == "owner_grant"]
cut = [r for r in rows if r.get("reason") == "grant_expired" and r.get("detail") == "connection_reset"]
if not grant or not cut:
    sys.exit(1)
m = re.search(r"until (\S+)", grant[0].get("detail", ""))
if not m:
    sys.exit(1)
lag = (ts(cut[0]["ts"]) - ts(m.group(1))).total_seconds()
print("  grant ends %s, reset receipt %s: %.3f s later" % (m.group(1), cut[0]["ts"], lag))
sys.exit(0 if 0 <= lag < 1.0 else 1)
PY
}
# Some sample before the cut saw bytes arriving.
stream_flowed() { grep -Eq '^  sample .* [1-9][0-9]* bytes$' "$LOG"; }
# curl failed before the six drips could finish (about 60 s), with fewer than their 6000 bytes.
stream_cut() {
    local line rc bytes secs
    line=$(grep 'inside: .* stream curl exit ' "$LOG") || return 1
    rc=$(echo "$line" | sed -n 's/.*stream curl exit \([0-9]*\) after.*/\1/p')
    bytes=$(echo "$line" | sed -n 's/.* after \([0-9]*\) bytes in.*/\1/p')
    secs=$(echo "$line" | sed -n 's/.* bytes in \([0-9]*\) s:.*/\1/p')
    [ -n "$rc" ] && [ -n "$bytes" ] && [ -n "$secs" ] && [ "$rc" -ne 0 ] && [ "$bytes" -lt 6000 ] && [ "$secs" -lt 40 ]
}

check "outside: the owner grant succeeds" grep -q "^outside: grant exit 0$" "$OWNER"
check "inside, right after the grant: $HOST through (CONNECT 200)" grep -Eq "$HOST right after the grant -> 200/2" "$LOG"
check "inside: the stream flowed under the grant" stream_flowed
check "inside: the stream was cut before its end (curl failed, under 6000 bytes, under 40 s)" stream_cut
check "inside, after the expiry: a new connection is refused (CONNECT 403)" grep -q "$HOST again, a new connection -> 403/" "$LOG"
check "receipt: the owner grant (owner_grant, $HOST, ${GRANT_SECONDS}s)" \
    has_receipt "$RCPT" event=grant reason=owner_grant host="$HOST" "detail~for ${GRANT_SECONDS}s"
check "receipt: the stream's tunnel allowed by the grant (granted, rule grant:$HOST)" \
    has_receipt "$RCPT" event=connect verdict=allow reason=granted rule="grant:$HOST"
check "receipt: the expiry reset the connection (grant_expired, connection_reset)" \
    has_receipt "$RCPT" event=connect verdict=deny reason=grant_expired host="$HOST" detail=connection_reset
check "receipt: the reset came within 1 s of the grant's end" expiry_on_time
check "receipt: the connection after the expiry refused by the policy (no_matching_rule)" \
    has_receipt "$RCPT" event=connect verdict=deny reason=no_matching_rule host="$HOST"
check "receipts: the scope's last receipt is scope_end" ends_with_scope_end "$RCPT"

show_receipts
summary
