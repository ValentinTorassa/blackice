#!/bin/bash
# Phase 5 fault tests on a Mac with blackice installed and its extension active. Four cases, all
# with one test configuration in ask mode:
#   1. daemon down: no daemon is registered, so a paused connection's event is not sent and the
#      connection is dropped at the deadline;
#   2. hook hung: a hook that sleeps past the deadline is killed, and the connection is dropped;
#   3. burst: BURST connections to distinct hosts and SAME to one host, at once: one event per app,
#      host and port, at most 64 connections per event, at most 4 hooks at once with the rest
#      waiting for a slot, those left when too little time remains logged as dropped
#      (deadline_near), and the Mac keeps working;
#   4. restart: the daemon is killed, launchd starts it again and it registers; then a
#      configuration change while connections wait cancels their events, and lets the connections
#      go since the new configuration allows them (`accept_all;configuration_changed`). That change
#      is the switch back to accept-all at the end.
# The hook is a program hook: /bin/sh with the test script, which the daemon starts only after
# checking that it is Apple's sh (com.apple.sh). It prints nothing, so it never answers.
# Touch ID twice: `blackice start` with the test configuration at the beginning, and
# `blackice mode accept-all` at the end. The daemon is stopped and started with
# `blackice agent uninstall` and `blackice agent install`.
#
# usage: macos/scripts/fault-test.sh
#        DRY=1 macos/scripts/fault-test.sh
#   DRY=1 writes the test configuration and hook, validates the configuration with a blackice
#   built from this package, runs the hook on sample events and the result checks on sample logs.
#   No Touch ID, no daemon, no network; nothing on the filter changes.
#   TIMEOUT=SECONDS  timeout_seconds in the test configuration (default 30)
#   BURST=N          connections to distinct hosts in the burst (default 50, at most 50)
#   SAME=N           connections to one host in the burst (default 70)
#   BIN=PATH         blackice (default /Applications/Blackice.app/Contents/MacOS/blackice;
#                    DRY: a debug build of this package)
#   OUT=DIR          work files (default ~/Library/Logs/blackice-fault-<time>; DRY:
#                    macos/build/fault-dry-<time>). Not under ~/Documents, ~/Desktop or
#                    ~/Downloads: the hooks run under launchd and cannot read there.
#   AGENT_LABEL=ID   the LaunchAgent's label (default com.valentorassa.blackice.daemon)
# For about four minutes the Mac is in ask mode with only the test's rules: apps without a rule
# wait up to TIMEOUT seconds and are then dropped. If the script stops for any reason, it switches
# back to accept-all on its way out (Touch ID) and leaves the LaunchAgent as it found it.
# Tailscale's DNS has to be off (docs/plan.md, "VPN and DNS proxies").
# shellcheck disable=SC2016 # the single-quoted jq and awk programs use $ for their own variables
set -euo pipefail
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd -- "$SCRIPTS/.." && pwd)"
FILTER_ID=com.valentorassa.blackice.filter
NSCURL_ID=com.apple.nscurl
EVENTS="$HOME/Library/Logs/blackice/events.jsonl"
AGENT_LABEL=${AGENT_LABEL:-com.valentorassa.blackice.daemon}
DRY=${DRY:-}
TIMEOUT=${TIMEOUT:-30}
BURST=${BURST:-50}
SAME=${SAME:-70}
JQ=${JQ:-/usr/bin/jq}
PER_EVENT=64  # PendingTable.maximumFlowsPerEvent
HOOK_SLOTS=4  # HookRunner.Options.maximumConcurrent
# Each case has its own hosts, so no connection joins another case's event. All of them resolve;
# the connections wait paused and are never let through, apart from the control.
DOWN_HOST=example.com
HUNG_HOST=example.net
SAME_HOST=example.org
RESTART_HOSTS=(www.example.com www.example.net)
CONTROL_HOST=pypi.org  # the system curl has a rule for it
BURST_HOSTS=(
    wikipedia.org mozilla.org debian.org kernel.org python.org rust-lang.org go.dev nodejs.org
    ruby-lang.org php.net perl.org haskell.org swift.org llvm.org gnu.org fsf.org apache.org
    eclipse.org gitlab.com bitbucket.org sourceforge.net stackoverflow.com ubuntu.com
    fedoraproject.org archlinux.org freebsd.org openbsd.org netbsd.org gentoo.org opensuse.org
    postgresql.org mysql.com sqlite.org mongodb.com redis.io nginx.org docker.com kubernetes.io
    w3.org ietf.org iana.org icann.org letsencrypt.org cloudflare.com fastly.com akamai.com
    duckduckgo.com archive.org openssl.org mariadb.org
)
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
whole() {
    if [[ ! "$2" =~ ^[0-9]+$ ]] || (( $2 < $3 || $2 > $4 )); then die "$1 must be a whole number from $3 to $4"; fi
}

if [[ $# -ne 0 ]]; then
    sed -n 17,30p "$0" >&2
    exit 64
fi
[[ "$(uname -s)" == Darwin ]] || die 'run this on macOS'
whole TIMEOUT "$TIMEOUT" 15 120
whole BURST "$BURST" 1 "${#BURST_HOSTS[@]}"
whole SAME "$SAME" 2 200
HOOK_BUSY=$((TIMEOUT / 2))   # busy hooks exit on their own, well before the deadline
HUNG_SLEEP=$((TIMEOUT * 4))  # the hung hook would outlive the deadline by far
MAXTIME=$((TIMEOUT + 15))    # nscurl's own limit, past the deadline
if [[ ! -x "$JQ" ]]; then JQ=$(command -v jq) || die 'jq is missing (macOS ships /usr/bin/jq)'; fi

if [[ -n "$DRY" ]]; then
    OUT="${OUT:-$MACOS_DIR/build/fault-dry-$(date +%Y%m%d-%H%M%S)}"
else
    OUT="${OUT:-$HOME/Library/Logs/blackice-fault-$(date +%Y%m%d-%H%M%S)}"
fi
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
# OUT goes into the hook's command line and the hook script unquoted.
[[ "$OUT" =~ ^[A-Za-z0-9._/+-]+$ ]] || die "OUT may hold only letters, digits and ._/+-: $OUT"
if [[ -z "$DRY" ]]; then
    case "$OUT" in
        "$HOME"/Documents/* | "$HOME"/Desktop/* | "$HOME"/Downloads/*)
            die "OUT is under ~/Documents, ~/Desktop or ~/Downloads, which the hooks cannot read" ;;
    esac
fi
[[ -e "$OUT" ]] && die "$OUT already exists; choose a fresh directory"
mkdir -p "$OUT/nscurl"
chmod 700 "$OUT"

# --- The test configuration and hook --------------------------------------------------------

printf '%s\n' "${BURST_HOSTS[@]:0:$BURST}" > "$OUT/burst-hosts.txt"
sed -e "s|@OUT@|$OUT|g" -e "s|@NSCURL_ID@|$NSCURL_ID|g" -e "s|@HUNG_HOST@|$HUNG_HOST|g" \
    -e "s|@HUNG_SLEEP@|$HUNG_SLEEP|g" -e "s|@HOOK_BUSY@|$HOOK_BUSY|g" > "$OUT/hook.sh" <<'EOF'
#!/bin/sh
# Test hook written by macos/scripts/fault-test.sh for one run. It takes the app and the host
# from the event file and appends one line per event to hook-calls.log: event ID, case, host and
# its own PID. It prints nothing on stdout, so it answers nothing.
dir='@OUT@'
id=$BLACKICE_EVENT_ID
case $id in '' | *[!a-z0-9-]*) id=invalid ;; esac
host=$(/usr/bin/plutil -extract host raw -o - "$BLACKICE_EVENT_FILE" 2>/dev/null) || host=
case $host in '' | *[!a-z0-9.-]*) host=invalid ;; esac
app=$(/usr/bin/plutil -extract app.signing_id raw -o - "$BLACKICE_EVENT_FILE" 2>/dev/null) || app=
note() { printf '%s %s %s %s\n' "$id" "$1" "$host" "$$" >> "$dir/hook-calls.log"; }
# FAULT_HOOK_DRY comes only from the dry run: the daemon gives hooks a fixed environment.
nap() { if [ -n "${FAULT_HOOK_DRY:-}" ]; then exit 0; fi; exec /bin/sleep "$1"; }
if [ "$app" != '@NSCURL_ID@' ]; then note other; exit 0; fi
if [ "$host" = '@HUNG_HOST@' ]; then
    # Only the first event hangs: a retry's event must not hold a hook slot into the burst.
    if mkdir "$dir/hung.lock" 2>/dev/null; then note hung; nap @HUNG_SLEEP@; fi
    note hung-again
    exit 0
fi
if /usr/bin/grep -qxF -- "$host" "$dir/burst-hosts.txt"; then note busy; nap @HOOK_BUSY@; fi
note plain
exit 0
EOF
chmod 700 "$OUT/hook.sh"
cat > "$OUT/fault.toml" <<EOF
# Written by macos/scripts/fault-test.sh for one run.
mode = "ask"
timeout_seconds = $TIMEOUT

# The control for "the Mac keeps working": the system curl may reach $CONTROL_HOST.
[[allow]]
app = "com.apple.curl"
hosts = ["$CONTROL_HOST"]

[[hook]]
on = "connection"
program = "/bin/sh"
app = "com.apple.sh"
args = ["$OUT/hook.sh"]
EOF

# --- Reading the results --------------------------------------------------------------------
# The event log is JSON Lines; a line still being written is skipped (fromjson?).

# Seconds since 1970 from the log's UTC timestamps, such as 2026-11-03T12:53:40.019Z.
JQ_SECS='def secs: capture("^(?<s>[^.Z]+)(\\.(?<f>[0-9]+))?Z$")
    | (.s + "Z" | fromdateiso8601) + ("0." + (.f // "0") | tonumber);'

# The first event nscurl raised for HOST, or nothing.
ev_for() {
    "$JQ" -Rnr --arg h "$1" --arg app "$NSCURL_ID" '[inputs | fromjson?
        | select(.type == "event_received" and .host == $h and .app_signing_id == $app) | .event]
        | first // empty' "$2"
}

# nscurl's events for HOST raised within WINDOW seconds of the first one: while it was pending.
ev_count() {
    "$JQ" -Rnr --arg h "$1" --arg app "$NSCURL_ID" --argjson w "$3" "$JQ_SECS"'[inputs | fromjson?
        | select(.type == "event_received" and .host == $h and .app_signing_id == $app) | .ts | secs] as $t
        | if ($t | length) == 0 then 0 else [$t[] | select(. < ($t | min) + $w)] | length end' "$2"
}

# One event's hook outcomes, verdicts, kill time in ms and seconds from event to verdict, tab-separated.
outcome() {
    "$JQ" -Rnr --arg e "$1" "$JQ_SECS"'[inputs | fromjson? | select(.event == $e)] as $r
        | ([$r[] | select(.type == "event_received") | .ts] | first) as $t0
        | ([$r[] | select(.type == "verdict")] | first) as $v
        | [([$r[] | select((.type // "") | test("^hook_(exited|killed|signaled|dropped|failed)$"))
                | .type + (if .reason then ":" + .reason else "" end)] | join(",")),
           ([$r[] | select(.type == "verdict") | .verdict] | join(",")),
           ([$r[] | select(.type == "hook_killed") | .duration_ms] | first // -1 | tostring),
           (if $t0 and $v then (($v.ts | secs) - ($t0 | secs)) * 10 | round / 10 | tostring else "-" end)]
        | map(if . == "" then "-" else . end) | @tsv' "$2"
}

# True once EVENT has a verdict and its hook has ended.
settled() {
    "$JQ" -Rne --arg e "$1" '[inputs | fromjson? | select(.event == $e)] as $r
        | ([$r[] | select(.type == "verdict")] | length > 0)
          and ([$r[] | select((.type // "") | test("^hook_(exited|killed|signaled|dropped|failed)$"))] | length > 0)' \
        "$2" > /dev/null
}

# For nscurl's events to the hosts in HOSTFILE: events, distinct hosts, hooks queued, hooks started,
# started after waiting, dropped while waiting (deadline_near, queue_full, event_ended), dropped
# otherwise, exited, failed, and events with no hook record at all; tab-separated.
burst_summary() {
    "$JQ" -Rnr --arg app "$NSCURL_ID" --rawfile hosts "$2" '
        ($hosts | split("\n") | map(select(length > 0))) as $h
        | [inputs | fromjson?] as $all
        | [$all[] | select(.type == "event_received" and .app_signing_id == $app and (.host as $x | $h | index($x)))] as $ev
        | ($ev | map(.event)) as $ids
        | [$all[] | select(.event as $e | $ids | index($e))] as $r
        | def n(f): [$r[] | select(f)] | length;
        def queue_drop: .type == "hook_dropped" and (.reason | IN("deadline_near", "queue_full", "event_ended"));
        [($ev | length), ([$ev[].host] | unique | length), n(.type == "hook_queued"), n(.type == "hook_started"),
         n(.type == "hook_started" and (.waited_ms // 0) > 0), n(queue_drop),
         n(.type == "hook_dropped" and (queue_drop | not)), n(.type == "hook_exited"),
         n(.type == "hook_failed")] as $c
        | $c + [$c[0] - $c[3] - $c[5] - $c[6] - $c[8]] | @tsv' "$1"
}

# The most hooks running at once: +1 at hook_started, -1 when a started hook ended. An end and a
# start in the same millisecond count the end first.
max_hooks() {
    "$JQ" -Rnr '[inputs | fromjson? | select((.type // "") | test("^hook_(started|exited|killed|signaled)$"))
        | {ts, d: (if .type == "hook_started" then 1 else -1 end)}]
        | sort_by(.ts, .d) | reduce .[] as $x ({c: 0, m: 0}; .c += $x.d | .m = ([.m, .c] | max)) | .m' "$1"
}

# From `blackice pending` output: is nscurl's event for HOST listed, and with how many connections.
# `blackice pending` lists a waiting connection as "  com.apple.nscurl → HOST:443  N connections, 25s left".
listed() {
    awk -v needle=" $NSCURL_ID → $2:443 " 'index($0, needle) {found = 1} END {exit !found}' "$1"
}
connections() {
    awk -v needle=" $NSCURL_ID → $2:443 " 'index($0, needle) && match($0, /  [0-9]+ connections?, /) {
        n = substr($0, RSTART + 2, RLENGTH - 2); sub(/ .*/, "", n); print n; exit }' "$1"
}

# True when a line of the filter log FILE contains TEXT and its time is within FROM..TO (epoch s).
logged_between() {
    local line t
    while IFS= read -r line; do
        t=$(date -j -f '%Y-%m-%d %H:%M:%S' "${line:0:19}" +%s 2>/dev/null) || continue
        if (( t >= $3 && t <= $4 )); then return 0; fi
    done < <(grep -F -- "$2" "$1" || true)
    return 1
}

count_in() { local n; n=$(grep -cF -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
between() { awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(x != "-" && x + 0 >= lo && x + 0 <= hi) }'; }
is() { if "$@"; then echo 1; else echo 0; fi; }

results=()
pass=true
verdict() {  # DESCRIPTION 1|0
    local line
    if [[ "$2" == 1 ]]; then line="PASS  $1"; else line="FAIL  $1"; pass=false; fi
    echo "$line"
    results+=("$line")
}

# --- DRY: check the files and the checks, then stop -----------------------------------------

if [[ -n "$DRY" ]]; then
    echo "DRY run: no Touch ID, no daemon, no network. Work files: $OUT"
    for tool in /usr/bin/nscurl /usr/bin/plutil /usr/bin/log /usr/bin/curl /bin/launchctl; do
        [[ -x "$tool" ]] || die "$tool is missing"
    done
    if [[ -z "${BIN:-}" ]]; then
        step "Build blackice from this package (debug)"
        swift build --package-path "$MACOS_DIR" -Xswiftc -warnings-as-errors --product blackice
        BIN="$(swift build --package-path "$MACOS_DIR" --show-bin-path)/blackice"
    fi

    step "The test configuration"
    cat "$OUT/fault.toml"
    valid=$("$BIN" validate "$OUT/fault.toml")
    echo "$valid"
    verdict "the configuration is valid (ask mode, 1 rule, 1 hook, $TIMEOUT s to answer)" \
        "$(is grep -qF "is valid: ask mode, 1 rule, 1 hook, $TIMEOUT s to answer" <<<"$valid")"
    hosts=("${BURST_HOSTS[@]}" "$DOWN_HOST" "$HUNG_HOST" "$SAME_HOST" "${RESTART_HOSTS[@]}" "$CONTROL_HOST")
    distinct=$(printf '%s\n' "${hosts[@]}" | sort -u | wc -l | tr -d ' ')
    verdict "the ${#hosts[@]} test hosts are distinct ($distinct)" "$(( distinct == ${#hosts[@]} ))"
    bad=$(printf '%s\n' "${hosts[@]}" | awk '!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/' | wc -l | tr -d ' ')
    verdict "every test host is a normalized host name ($bad not)" "$(( bad == 0 ))"

    step "The test hook on sample events"
    /bin/sh -n "$OUT/hook.sh"
    mkdir -p "$OUT/dry"
    run_hook() {  # ID APP-JSON HOST
        printf '{"event":"connection","id":"%s","app":%s,"host":"%s","ip":"203.0.113.7","port":443,"deadline":"2026-11-03T14:36:11Z"}\n' \
            "$1" "$2" "$3" > "$OUT/dry/$1.json"
        env -i FAULT_HOOK_DRY=1 BLACKICE_EVENT_FILE="$OUT/dry/$1.json" BLACKICE_EVENT_ID="$1" PATH=/usr/bin:/bin \
            /bin/sh "$OUT/hook.sh" < "$OUT/dry/$1.json" >> "$OUT/dry/stdout.txt"
    }
    nscurl_app="{\"signing_id\":\"$NSCURL_ID\",\"path\":\"/usr/bin/nscurl\"}"
    run_hook ev-00000001 "$nscurl_app" "$HUNG_HOST"
    run_hook ev-00000002 "$nscurl_app" "$HUNG_HOST"
    run_hook ev-00000003 "$nscurl_app" "${BURST_HOSTS[0]}"
    run_hook ev-00000004 "$nscurl_app" "${RESTART_HOSTS[0]}"
    run_hook ev-00000005 '{"signing_id":"com.apple.cloudd"}' gateway.icloud.com
    run_hook ev-00000006 '{"cdhash":"0123456789abcdef0123456789abcdef01234567"}' api.github.com
    run_hook ev-00000007 "$nscurl_app" 'Bad$(name)'
    calls=$(cat "$OUT/hook-calls.log")
    echo "$calls"
    got=$(awk '{print $1 " " $2 " " $3}' <<<"$calls")
    want="ev-00000001 hung $HUNG_HOST
ev-00000002 hung-again $HUNG_HOST
ev-00000003 busy ${BURST_HOSTS[0]}
ev-00000004 plain ${RESTART_HOSTS[0]}
ev-00000005 other gateway.icloud.com
ev-00000006 other api.github.com
ev-00000007 plain invalid"
    verdict "the hook picks hung once, busy, plain and other as planned" "$(is test "$got" == "$want")"
    verdict "the hook printed nothing, so it never answers" "$(is test ! -s "$OUT/dry/stdout.txt")"
    command rm -rf -- "$OUT/hung.lock" "$OUT/hook-calls.log"

    step "The result checks on sample logs"
    S=$OUT/dry/events.jsonl
    b0=${BURST_HOSTS[0]} b1=${BURST_HOSTS[1]} b2=${BURST_HOSTS[2]} b3=${BURST_HOSTS[3]} b4=${BURST_HOSTS[4]} b5=${BURST_HOSTS[5]}
    {
        e() { printf '{"ts":"2026-11-03T10:%sZ","type":"event_received","event":"%s","app_signing_id":"%s","host":"%s","ip":"203.0.113.7","port":443,"deadline":"2026-11-03T10:59:00Z"}\n' "$1" "$2" "$3" "$4"; }
        r() { printf '{"ts":"2026-11-03T10:%sZ","type":"%s","event":"%s","hook_line":11%s}\n' "$1" "$2" "$3" "${4:-}"; }
        e 00:00.100 ev-b0 "$NSCURL_ID" "$b0"; r 00:00.101 hook_started ev-b0 ',"pid":101'
        e 00:00.110 ev-b1 "$NSCURL_ID" "$b1"; r 00:00.111 hook_started ev-b1 ',"pid":102'
        e 00:00.120 ev-b2 "$NSCURL_ID" "$b2"; r 00:00.121 hook_started ev-b2 ',"pid":103'
        e 00:00.130 ev-b3 "$NSCURL_ID" "$b3"; r 00:00.131 hook_started ev-b3 ',"pid":104'
        e 00:00.140 ev-b4 "$NSCURL_ID" "$b4"; r 00:00.141 hook_queued ev-b4 ',"waiting":1'
        e 00:00.150 ev-b5 "$NSCURL_ID" "$b5"; r 00:00.151 hook_queued ev-b5 ',"waiting":2'
        e 00:00.500 ev-s1 "$NSCURL_ID" "$SAME_HOST"; r 00:00.501 hook_queued ev-s1 ',"waiting":3'
        printf '{"ts":"2026-11-03T10:00:00.600Z","type":"event_rec\n'   # a line cut short
        # A hook ends and a waiting one starts in the same millisecond while three still run.
        r 00:10.300 hook_exited ev-b3 ',"status":0,"duration_ms":10169'
        r 00:10.300 hook_started ev-b4 ',"pid":105,"waited_ms":10159'
        e 00:10.290 ev-o1 com.apple.cloudd gateway.icloud.com; r 00:10.291 hook_queued ev-o1 ',"waiting":3'
        r 00:15.101 hook_exited ev-b0 ',"status":0,"duration_ms":15000'
        r 00:15.101 hook_started ev-o1 ',"pid":106,"waited_ms":4810'
        r 00:15.111 hook_exited ev-b1 ',"status":0,"duration_ms":15000'
        r 00:15.111 hook_started ev-s1 ',"pid":107,"waited_ms":14610'
        r 00:15.121 hook_exited ev-b2 ',"status":0,"duration_ms":15000'
        r 00:15.140 hook_exited ev-o1 ',"status":0,"duration_ms":39,"waited_ms":4810'
        r 00:15.200 hook_exited ev-s1 ',"status":0,"duration_ms":89,"waited_ms":14610'
        r 00:20.151 hook_dropped ev-b5 ',"reason":"deadline_near","duration_ms":0,"waited_ms":20000'
        r 00:25.000 hook_exited ev-b4 ',"status":0,"duration_ms":14700,"waited_ms":10159'
        e 05:00.000 ev-s2 "$NSCURL_ID" "$SAME_HOST"   # a retry long after the first event ended
        e 01:00.000 ev-h1 "$NSCURL_ID" "$HUNG_HOST"; r 01:00.002 hook_started ev-h1 ',"pid":108'
        r 01:30.010 hook_killed ev-h1 ',"reason":"deadline","signal":15,"duration_ms":30008'
        printf '{"ts":"2026-11-03T10:01:30.600Z","type":"verdict","event":"ev-h1","verdict":"timed_out"}\n'
        e 02:00.000 ev-r1 "$NSCURL_ID" "${RESTART_HOSTS[0]}"
        printf '{"ts":"2026-11-03T10:02:05.250Z","type":"verdict","event":"ev-r1","verdict":"cancelled"}\n'
    } > "$S"
    printf '%s\n' "$b0" "$b1" "$b2" "$b3" "$b4" "$b5" > "$OUT/dry/hosts.txt"
    verdict "ev_for finds the hung host's event" "$(is test "$(ev_for "$HUNG_HOST" "$S")" == ev-h1)"
    verdict "ev_for finds nothing for a host with no event" "$(is test -z "$(ev_for "$DOWN_HOST" "$S")")"
    verdict "ev_count counts one event while it was pending" "$(is test "$(ev_count "$SAME_HOST" "$S" $((TIMEOUT - 1)))" -eq 1)"
    got=$(outcome ev-h1 "$S")
    verdict "outcome reads the killed hook and the timed-out verdict ($got)" \
        "$(is test "$got" == "$(printf 'hook_killed:deadline\ttimed_out\t30008\t30.6')")"
    verdict "outcome reads a cancelled event" "$(is test "$(outcome ev-r1 "$S")" == "$(printf -- '-\tcancelled\t-1\t5.3')")"
    verdict "settled waits for a verdict and a hook end" "$(is settled ev-h1 "$S")"
    verdict "settled is false without a hook end" "$(is test "$(is settled ev-r1 "$S")" == 0)"
    got=$(burst_summary "$S" "$OUT/dry/hosts.txt")
    verdict "burst_summary counts events, waits, starts and drops ($got)" \
        "$(is test "$got" == "$(printf '6\t6\t2\t5\t1\t1\t0\t5\t0\t0')")"
    verdict "max_hooks sees 4 at once, an end and a start in the same ms counted once" "$(is test "$(max_hooks "$S")" -eq 4)"
    printf '%s\n' 'Waiting' \
        "  $NSCURL_ID → $SAME_HOST:443  64 connections, 25s left" \
        "    blackice approve --app $NSCURL_ID --host $SAME_HOST" \
        "  $NSCURL_ID → $HUNG_HOST:443  1 connection, 25s left" \
        "    blackice approve --app $NSCURL_ID --host $HUNG_HOST" '' 'Approvals' \
        "  $NSCURL_ID → www.$DOWN_HOST  10m" > "$OUT/dry/pending.txt"
    verdict "connections reads 64 from the pending list" "$(is test "$(connections "$OUT/dry/pending.txt" "$SAME_HOST")" == 64)"
    verdict "connections reads 1 connection" "$(is test "$(connections "$OUT/dry/pending.txt" "$HUNG_HOST")" == 1)"
    verdict "listed is false for a host not waiting" "$(is test "$(is listed "$OUT/dry/pending.txt" "$DOWN_HOST")" == 0)"
    now=$(date +%s)
    printf '%s Df com.valentorassa.blackice.filter[1:2] [%s:flows] flow drop timeout <private>\n' \
        "$(date -r "$now" '+%Y-%m-%d %H:%M:%S').123" "$FILTER_ID" > "$OUT/dry/filter.log"
    verdict "logged_between finds a line in its window" "$(is logged_between "$OUT/dry/filter.log" 'flow drop timeout' $((now - 1)) $((now + 1)))"
    verdict "logged_between ignores a line outside it" \
        "$(is test "$(is logged_between "$OUT/dry/filter.log" 'flow drop timeout' $((now + 5)) $((now + 9)))" == 0)"

    step "DRY result"
    echo "A real run asks for Touch ID twice and keeps the Mac in ask mode for about four minutes:"
    echo "  1. daemon down ($DOWN_HOST), 2. hook hung ($HUNG_HOST), 3. burst ($BURST hosts, $SAME x $SAME_HOST),"
    echo "  4. restart and configuration change (${RESTART_HOSTS[*]}). Timeout $TIMEOUT s."
    $pass
    echo "DRY run passed. Work files: $OUT"
    exit 0
fi

# --- The real run ---------------------------------------------------------------------------

BIN=${BIN:-/Applications/Blackice.app/Contents/MacOS/blackice}
gui_target() { echo "gui/$(id -u)/$AGENT_LABEL"; }
agent_loaded() { launchctl print "$(gui_target)" > /dev/null 2>&1; }
agent_gone() { ! agent_loaded; }
agent_pid() {
    local text
    text=$(launchctl print "$(gui_target)" 2>/dev/null) || return 0
    awk '$1 == "pid" && $2 == "=" {print $3; exit}' <<<"$text"
}
until_true() {  # SECONDS COMMAND...: polls once a second
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
}
log_now() { date '+%Y-%m-%d %H:%M:%S'; }
# The filter's lines from START on, from the run's own `log stream` copy (STREAM, started below):
# `log show` does not always keep them, as on a nearly full disk on 6 November 2026.
filter_log() {  # START FILE
    sleep 2  # the newest lines can take a moment to arrive
    awk -v from="$1" 'substr($0, 1, 19) >= from' "$STREAM" > "$2"
}
registered_since() {
    awk -v from="$1" 'substr($0, 1, 19) >= from && index($0, "control xpc daemon_registered") {found = 1}
        END {exit !found}' "$STREAM"
}
event_offset() { if [[ -f "$EVENTS" ]]; then stat -f %z "$EVENTS"; else echo 0; fi; }
slice() { if [[ -f "$EVENTS" ]]; then tail -c +"$(($1 + 1))" "$EVENTS" > "$2"; else : > "$2"; fi; }
settle() {  # OFFSET FILE HOST SECONDS: re-reads the event log until HOST's event has settled
    local deadline=$((SECONDS + $4)) ev
    while :; do
        slice "$1" "$2"
        ev=$(ev_for "$3" "$2")
        if [[ -n "$ev" ]] && settled "$ev" "$2"; then return 0; fi
        (( SECONDS < deadline )) || return 0
        sleep 1
    done
}
launch() { /usr/bin/nscurl -I -m "$MAXTIME" "$2" > "$OUT/nscurl/$1.out" 2>&1 & }
stop_at() {  # PID EPOCH: waits for our own background nscurl until EPOCH, then stops it
    while kill -0 "$1" 2>/dev/null && (( $(date +%s) < $2 )); do sleep 1; done
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}
stop_jobs() {
    local left
    left=$(jobs -pr) || left=
    # shellcheck disable=SC2086 # one PID per word
    if [[ -n "$left" ]]; then kill $left 2>/dev/null || true; fi
    wait 2>/dev/null || true
}
result_of() {
    local text
    text=$(cat -- "$OUT/nscurl/$1.out" 2>/dev/null) || text=
    if grep -Eq '^HTTP/[0-9.]+ [0-9]{3}' <<<"$text"; then echo http
    elif grep -qF 'Load failed' <<<"$text"; then echo failed
    else echo other; fi
}
hook_called() { awk -v e="$1" -v c="$2" '$1 == e && $2 == c {found = 1} END {exit !found}' "$OUT/hook-calls.log" 2>/dev/null; }

started='' restored='' agent_before='' agent_touched='' STREAM=''
cleanup() {
    local status=$?
    trap '' INT TERM HUP
    trap - EXIT
    stop_jobs
    if [[ -n "$STREAM" && -f "$OUT/stream.pid" ]]; then kill "$(cat "$OUT/stream.pid")" 2>/dev/null || true; fi
    if [[ -n "$started" && -z "$restored" ]]; then
        echo "Switching back to accept-all: Touch ID."
        if "$BIN" mode accept-all; then restored=1; else
            echo "Could not switch back. Run: \"$BIN\" mode accept-all (docs/install.md, Rollback)" >&2
        fi
    fi
    if [[ -n "$agent_touched" ]]; then
        if [[ -n "$agent_before" ]] && ! agent_loaded; then
            "$BIN" agent install || echo "Could not start the daemon again: \"$BIN\" agent install" >&2
        elif [[ -z "$agent_before" ]] && agent_loaded; then
            "$BIN" agent uninstall || echo "Could not remove the daemon: \"$BIN\" agent uninstall" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

step "Check the Mac"
[[ -x "$BIN" ]] || die "no blackice at $BIN; install it first (docs/install.md)"
for tool in /usr/bin/nscurl /usr/bin/plutil /usr/bin/log /usr/bin/curl /usr/bin/dscacheutil; do
    [[ -x "$tool" ]] || die "$tool is missing"
done
help=$("$BIN" help 2>&1) || help=
grep -qF 'agent install' <<<"$help" || die "$BIN has no 'agent install'; this test needs a build with it"
listed_ext=$(systemextensionsctl list 2>/dev/null) || listed_ext=
awk -v id="$FILTER_ID" 'index($0, id) && /activated enabled/ {found = 1} END {exit !found}' <<<"$listed_ext" \
    || die "the extension is not activated and enabled; run blackice start first (docs/install.md)"
"$BIN" status || die "blackice status failed"
dns=$(scutil --dns 2>/dev/null) || dns=
if grep -qF 100.100.100.100 <<<"$dns"; then
    die "Tailscale's DNS is on, and names stop resolving in ask mode. Run: tailscale set --accept-dns=false"
fi
# A case waits on a connection to its own host, so a name that does not resolve fails the case with
# no connection for the filter to see. On 10 November 2026 a router answered NXDOMAIN for
# example.com and www.example.com, and six checks of cases 1 and 4 failed for that.
for host in "$DOWN_HOST" "$HUNG_HOST" "$SAME_HOST" "${RESTART_HOSTS[@]}" "$CONTROL_HOST"; do
    answers=$(/usr/bin/dscacheutil -q host -a name "$host" 2>/dev/null) || answers=
    grep -q '_address: ' <<<"$answers" \
        || die "$host does not resolve with this Mac's DNS server, and a case needs it; run the test on another network or DNS server"
done
"$BIN" validate "$OUT/fault.toml"
state='not loaded'
if agent_loaded; then agent_before=1 state=loaded; fi
echo "LaunchAgent $AGENT_LABEL: $state; it is left that way at the end."
echo "Work files: $OUT"
# Started in a subshell, so stop_jobs between the cases leaves it running; cleanup stops it.
STREAM="$OUT/stream.log"
( /usr/bin/log stream --style compact --predicate "subsystem == \"$FILTER_ID\"" > "$STREAM" 2>&1 &
  echo $! > "$OUT/stream.pid" )
sleep 2
OFF0=$(event_offset)

step "Stop the daemon before ask mode starts"
agent_touched=1
if agent_loaded; then
    "$BIN" agent uninstall
    until_true 15 agent_gone || die "the LaunchAgent is still loaded after blackice agent uninstall"
fi
echo "No daemon runs."

step "Ask mode with the test configuration: Touch ID (1 of 2)"
started=1
"$BIN" start --config "$OUT/fault.toml" || die "blackice start failed"
sleep 2

step "1. Daemon down: a connection waits with no daemon registered"
off=$(event_offset) since=$(log_now) t0=$(date +%s)
launch down "https://$DOWN_HOST/"
pid=$!
sleep 5
"$BIN" pending > "$OUT/1-pending.txt" 2>&1 || true
cat "$OUT/1-pending.txt"
stop_at "$pid" $((t0 + TIMEOUT + 3))
secs=$(($(date +%s) - t0)) result=$(result_of down)
filter_log "$since" "$OUT/1-filter.log"
slice "$off" "$OUT/1-events.jsonl"
not_sent=$(count_in 'control event_not_sent no_daemon' "$OUT/1-filter.log")
verdict "1. the connection to $DOWN_HOST waited in the pending list" "$(is listed "$OUT/1-pending.txt" "$DOWN_HOST")"
verdict "1. the filter logged 'control event_not_sent no_daemon' ($not_sent)" "$(( not_sent >= 1 ))"
verdict "1. no event reached the event log" "$(is test -z "$(ev_for "$DOWN_HOST" "$OUT/1-events.jsonl")")"
verdict "1. the filter logged 'flow drop timeout' at the deadline, $TIMEOUT s in" \
    "$(is logged_between "$OUT/1-filter.log" 'flow drop timeout' $((t0 + TIMEOUT - 2)) $((t0 + TIMEOUT + 4)))"
ok=0; if [[ "$result" != http ]] && (( secs >= TIMEOUT - 1 )); then ok=1; fi
verdict "1. nscurl got no response and waited at least the timeout ($result after $secs s)" "$ok"

step "Daemon back: blackice agent install"
since=$(log_now)
"$BIN" agent install
registered=$(is until_true 30 registered_since "$since")
verdict "the daemon registered with the filter ('control xpc daemon_registered')" "$registered"
[[ "$registered" == 1 ]] || die "no daemon registered; the other cases need one"

step "2. Hook hung: the test hook sleeps past the deadline for $HUNG_HOST"
off=$(event_offset) t0=$(date +%s)
launch hung "https://$HUNG_HOST/"
pid=$!
stop_at "$pid" $((t0 + TIMEOUT + 3))
secs=$(($(date +%s) - t0)) result=$(result_of hung)
settle "$off" "$OUT/2-events.jsonl" "$HUNG_HOST" 15
ev=$(ev_for "$HUNG_HOST" "$OUT/2-events.jsonl")
IFS=$'\t' read -r hooks verdicts kill_ms wait_s <<<"$(outcome "${ev:-none}" "$OUT/2-events.jsonl")"
hung_pid=$(awk -v e="${ev:-none}" '$1 == e && $2 == "hung" {print $4; exit}' "$OUT/hook-calls.log" 2>/dev/null) || hung_pid=
left=
if [[ -n "$hung_pid" ]]; then left=$(ps -p "$hung_pid" -o command= 2>/dev/null) || left=; fi
verdict "2. the daemon received the event (${ev:-none}) and the hook took the hung case" \
    "$(is hook_called "${ev:-none}" hung)"
ok=0; if [[ "$hooks" == hook_killed:deadline ]] && between "$kill_ms" $(((TIMEOUT - 2) * 1000)) $(((TIMEOUT + 4) * 1000)); then ok=1; fi
verdict "2. the hook was killed at the deadline ($hooks after $kill_ms ms)" "$ok"
ok=0; if [[ "$verdicts" == timed_out ]] && between "$wait_s" $((TIMEOUT - 1)) $((TIMEOUT + 3)); then ok=1; fi
verdict "2. the connection was dropped at the deadline (verdict $verdicts, $wait_s s after the event)" "$ok"
ok=0; if [[ -n "$hung_pid" && "$left" != */bin/sleep* ]]; then ok=1; fi
verdict "2. the hook's sleep is gone (pid ${hung_pid:-none})" "$ok"
verdict "2. nscurl got no response ($result after $secs s)" "$(is test "$result" != http)"

step "3. Burst: $BURST connections to distinct hosts and $SAME to $SAME_HOST, at once"
off=$(event_offset) since=$(log_now) t0=$(date +%s)
for ((i = 0; i < BURST; i++)); do launch "burst-$i" "https://${BURST_HOSTS[$i]}/"; done
for ((i = 1; i <= SAME; i++)); do launch "same-$i" "https://$SAME_HOST/"; done
sleep 3
c0=$(date +%s)
code=$(/usr/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://$CONTROL_HOST/" 2> "$OUT/3-curl.err") || true
curl_s=$(($(date +%s) - c0))
status_ok=0
if "$BIN" status > "$OUT/3-status.txt" 2>&1; then status_ok=1; fi
"$BIN" pending > "$OUT/3-pending.txt" 2>&1 || true
same_n=$(connections "$OUT/3-pending.txt" "$SAME_HOST")
waiting=0
for ((i = 0; i < BURST; i++)); do if listed "$OUT/3-pending.txt" "${BURST_HOSTS[$i]}"; then waiting=$((waiting + 1)); fi; done
echo "Pending: $SAME_HOST with ${same_n:-no} connections, $waiting of $BURST burst hosts waiting."
# Past the deadline nscurl would retry and raise new events; stop the burst there.
while (( $(date +%s) < t0 + TIMEOUT + 3 )); do sleep 1; done
stop_jobs
sleep 2
slice "$off" "$OUT/3-events.jsonl"
filter_log "$since" "$OUT/3-filter.log"
slice "$OFF0" "$OUT/events.jsonl"
IFS=$'\t' read -r b_events b_hosts b_queued b_started b_waited b_queue_drop b_other b_exited b_failed b_missing \
    <<<"$(burst_summary "$OUT/3-events.jsonl" "$OUT/burst-hosts.txt")"
same_events=$(ev_count "$SAME_HOST" "$OUT/3-events.jsonl" $((TIMEOUT - 1)))
capacity=$(count_in 'flow drop ask_capacity' "$OUT/3-filter.log")
most=$(max_hooks "$OUT/events.jsonl")
listed_ext=$(systemextensionsctl list 2>/dev/null) || listed_ext=
verdict "3. the $SAME connections to $SAME_HOST shared one event ($same_events)" "$(( same_events == 1 ))"
ok=0; if [[ -n "$same_n" ]] && (( same_n >= 2 && same_n <= PER_EVENT )); then ok=1; fi
verdict "3. that event held ${same_n:-no} connections, at most $PER_EVENT" "$ok"
if (( SAME > PER_EVENT )); then
    verdict "3. connections over $PER_EVENT per event were dropped ('flow drop ask_capacity': $capacity)" "$(( capacity >= 1 ))"
fi
verdict "3. $b_hosts of $BURST distinct hosts raised an event ($b_events events)" "$(( b_hosts * 10 >= BURST * 8 ))"
verdict "3. at most $HOOK_SLOTS hooks ran at once (most seen in the event log: $most)" "$(( most >= 1 && most <= HOOK_SLOTS ))"
verdict "3. hooks over the limit waited for a slot ($b_queued queued, $b_waited of $b_started started after waiting)" \
    "$(( b_queued >= 1 && b_waited >= 1 ))"
verdict "3. every burst event ran its hook or was logged as dropped ($b_missing with no record, $b_queue_drop dropped while waiting, $b_other dropped otherwise, $b_failed failed)" \
    "$(( b_missing == 0 && b_failed == 0 ))"
verdict "3. curl reached $CONTROL_HOST during the burst (HTTP $code after $curl_s s)" "$(is test "$code" == 200)"
verdict "3. blackice status answered during the burst" "$status_ok"
refused=$(count_in '"type":"hook_refused"' "$OUT/events.jsonl")
verdict "3. the daemon started /bin/sh after checking its signature, and refused none ($refused hook_refused)" \
    "$(( b_started >= 1 && refused == 0 ))"
verdict "3. the extension is still activated and enabled" \
    "$(is awk -v id="$FILTER_ID" 'index($0, id) && /activated enabled/ {found = 1} END {exit !found}' <<<"$listed_ext")"
echo "($b_exited busy hooks exited on their own.)"

step "4. Restart: kill the daemon; launchd starts it again"
pid0=$(agent_pid)
[[ -n "$pid0" ]] || die "launchctl shows no running daemon for $AGENT_LABEL"
command_line=$(ps -p "$pid0" -o command= 2>/dev/null) || command_line=
[[ "$command_line" == *blackice* ]] || die "pid $pid0 is not blackice: $command_line"
since=$(log_now) k0=$(date +%s)
launchctl kill 9 "$(gui_target)"
registered=$(is until_true 40 registered_since "$since")
reg_s=$(($(date +%s) - k0))
pid1=$(agent_pid)
verdict "4. launchd started the daemon again (pid $pid0, then ${pid1:-none})" "$(is test -n "$pid1" -a "$pid1" != "$pid0")"
verdict "4. the new daemon registered with the filter ('control xpc daemon_registered', seen within $reg_s s)" "$registered"

step "4. A configuration change while connections wait: Touch ID (2 of 2)"
off=$(event_offset) since=$(log_now) t0=$(date +%s)
launch restart-0 "https://${RESTART_HOSTS[0]}/"
launch restart-1 "https://${RESTART_HOSTS[1]}/"
sleep 4
"$BIN" pending > "$OUT/4-pending.txt" 2>&1 || true
cat "$OUT/4-pending.txt"
echo "Touch ID now: switching back to accept-all is the configuration change this case tests."
"$BIN" mode accept-all && restored=1
change_s=$(($(date +%s) - t0))
# In accept-all the waiting nscurl requests go on; whether they then get an answer is not part of
# the check.
while (( $(date +%s) < t0 + change_s + 10 )) && [[ -n "$(jobs -pr)" ]]; do sleep 1; done
stop_jobs
settle "$off" "$OUT/4-events.jsonl" "${RESTART_HOSTS[1]}" 10
settle "$off" "$OUT/4-events.jsonl" "${RESTART_HOSTS[0]}" 5
filter_log "$since" "$OUT/4-filter.log"
received=0 cancelled=0 waited=0 seen=
for host in "${RESTART_HOSTS[@]}"; do
    ev=$(ev_for "$host" "$OUT/4-events.jsonl")
    if [[ -n "$ev" ]] && hook_called "$ev" plain; then received=$((received + 1)); fi
    IFS=$'\t' read -r hooks verdicts kill_ms wait_s <<<"$(outcome "${ev:-none}" "$OUT/4-events.jsonl")"
    if [[ "$verdicts" == cancelled ]]; then cancelled=$((cancelled + 1)); fi
    if listed "$OUT/4-pending.txt" "$host"; then waited=$((waited + 1)); fi
    seen="$seen $host:$verdicts"
done
released=$(count_in 'flow allow accept_all;configuration_changed' "$OUT/4-filter.log")
installed=$(count_in 'control configuration_installed mode accept-all' "$OUT/4-filter.log")
verdict "4. the new daemon received both events and ran the hook ($received of 2)" "$(( received == 2 ))"
verdict "4. both connections were waiting before the change ($waited of 2 in the pending list; change $change_s s in)" \
    "$(( waited == 2 ))"
verdict "4. the filter installed the change ('control configuration_installed mode accept-all')" "$(( installed >= 1 ))"
verdict "4. accept-all let the paused connections go ('flow allow accept_all;configuration_changed': $released)" \
    "$(( released >= 1 ))"
verdict "4. their events were cancelled ($cancelled of 2:$seen)" "$(( cancelled == 2 ))"

step "Result"
slice "$OFF0" "$OUT/events.jsonl"
printf '%s\n' "${results[@]}"
echo "Work files: $OUT (the event log lines of this run are in events.jsonl)"
echo "The filter keeps the test configuration, in accept-all. To load yours (Touch ID):"
echo "  \"$BIN\" start --config ~/.config/blackice/blackice.toml"
echo "Record the run in evidence/ as P5-01-faults-macos.md (see evidence/README.md)."
$pass
