# Shared helpers for the end-to-end scripts. Sourced, not run. Works with bash 3.2 (macOS) and later.
#
# Each script runs a built blackice against a synthetic policy, with real commands and real network, and
# prints one PASS or FAIL line per check, then a summary. It never reads credentials: any key it needs is
# synthetic and written by the script itself.

E2E_PASS=0
E2E_FAIL=0

pass() { echo "PASS  $*"; E2E_PASS=$((E2E_PASS + 1)); }
fail() { echo "FAIL  $*"; E2E_FAIL=$((E2E_FAIL + 1)); }

# check DESCRIPTION COMMAND [ARG]...: PASS when COMMAND succeeds.
check() {
    local what="$1"
    shift
    if "$@"; then pass "$what"; else fail "$what"; fi
}

# summary: prints the totals and returns 1 when anything failed.
summary() {
    echo
    echo "== $E2E_PASS passed, $E2E_FAIL failed"
    [ "$E2E_FAIL" -eq 0 ]
}

# die MESSAGE: a missing prerequisite. Nothing was checked, so this is neither a pass nor a fail.
die() {
    echo "NOT RUN  $*"
    exit 2
}

E2E_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

# The blackice binary under test: $BLACKICE, else the repo's zig-out build.
e2e_blackice() {
    B="${BLACKICE:-$E2E_REPO/zig-out/bin/blackice}"
    [ -x "$B" ] || die "no blackice binary at $B (zig build, or set BLACKICE=/path/to/blackice)"
    B=$(cd "$(dirname "$B")" && pwd -P)/$(basename "$B")
}

# A fresh working directory. Scoped commands run with it as their current directory, and the state root
# (XDG_STATE_HOME) is inside it, so the scope can see its own receipts and must not be able to change them.
e2e_workdir() {
    if [ -n "${E2E_DIR:-}" ]; then
        # Never delete what the caller names: the directory must be new or empty.
        if [ -e "$E2E_DIR" ] && [ -n "$(ls -A "$E2E_DIR" 2> /dev/null || echo x)" ]; then
            die "E2E_DIR=$E2E_DIR exists and is not an empty directory; name a new one"
        fi
        mkdir -p "$E2E_DIR" || die "cannot create $E2E_DIR"
        W=$(cd "$E2E_DIR" && pwd -P)
    else
        # Under /tmp, not $TMPDIR: the control socket path must stay short (see below).
        W=$(mktemp -d /tmp/bi-e2e.XXXXXX) || die "mktemp failed"
        W=$(cd "$W" && pwd -P)
    fi
    # A Unix socket path has at most 103 bytes on macOS (107 on Linux); each scope's control.sock lives here.
    local sock="$W/state/blackice/scopes/s-00000000/control.sock"
    [ "${#sock}" -le 103 ] || die "work dir $W is too long for the scopes' control socket (${#sock} > 103 bytes); set E2E_DIR to a short new path"
    export XDG_STATE_HOME="$W/state"
    mkdir -p "$XDG_STATE_HOME" "$W/out"
    chmod 700 "$W" "$XDG_STATE_HOME"
    cd "$W" || die "cannot enter $W"
}

# The synthetic policy every script uses: two public names, nothing else.
e2e_policy() {
    POLICY="$W/agent.json"
    cat > "$POLICY" <<'JSON'
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com", "registry.npmjs.org"]
  }
}
JSON
    "$B" policy check "$POLICY" > "$W/out/policy-check.txt" 2>&1 || {
        cat "$W/out/policy-check.txt"
        die "blackice policy check refused the synthetic policy"
    }
}

# scoped NAME [RUN OPTION]... -- CMD [ARG]...
# Runs `blackice run --policy $POLICY [RUN OPTION]... -- CMD...` and shows the command and its output.
# Sets RC (exit status), OUT (stdout file), ERR (stderr file), SID (scope id) and RCPT (receipts file).
scoped() {
    local name="$1"
    shift
    OUT="$W/out/$name.out"
    ERR="$W/out/$name.err"
    echo
    echo "\$ blackice run --policy agent.json $*"
    # Through pipes, not straight into files: some builds write their own lines at fixed file offsets, which
    # overwrites the command's output in a regular file. stdout -> OUT, stderr -> ERR; RC via a file because
    # the braces run in a subshell.
    { "$B" run --policy "$POLICY" "$@" < /dev/null 2>&1 1>&3 3>&- | cat > "$ERR"; echo "${PIPESTATUS[0]}" > "$W/out/$name.rc"; } 3>&1 | cat > "$OUT"
    RC=$(cat "$W/out/$name.rc")
    sed 's/^/  | /' "$OUT"
    grep -v '^blackice: scope ' "$ERR" | sed 's/^/  ! /'
    echo "  [exit $RC]"
    scope_of "$ERR"
}

# scope_of FILE: reads SID and RCPT from blackice's "blackice: scope s-... ; receipts: PATH" line.
scope_of() {
    SID=$(sed -n 's/^blackice: scope \(s-[0-9a-f]*\) .*/\1/p' "$1" | head -1)
    RCPT=$(sed -n 's/^blackice: scope .*; receipts: \(.*\)$/\1/p' "$1" | head -1)
    [ -n "$SID" ] && [ -f "$RCPT" ]
}

# rq FILE CONDITION...: prints how many receipts in FILE match every CONDITION.
#   key=value   the field equals value (numbers compare as text)
#   key~text    the field contains text
#   line~text   the raw line contains text
E2E_RQ='
import json, sys
path, conds = sys.argv[1], sys.argv[2:]
n = 0
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    ok = True
    for c in conds:
        eq, ct = c.find("="), c.find("~")
        if ct >= 0 and (eq < 0 or ct < eq):
            k, v = c.split("~", 1)
            have = line if k == "line" else str(r.get(k, ""))
            ok = v in have
        else:
            k, v = c.split("=", 1)
            ok = k in r and str(r[k]) == v
        if not ok:
            break
    n += ok
print(n)
'
rq() { python3 -I -c "$E2E_RQ" "$@"; }

# has_receipt FILE CONDITION...: true when at least one receipt matches.
has_receipt() { [ "$(rq "$@")" -gt 0 ]; }

# The last receipt of a finished scope must be its scope_end.
ends_with_scope_end() { tail -n 1 "$1" | grep -q '"event":"scope_end"'; }

# Prints every receipt of this run, one scope after another.
show_receipts() {
    echo
    echo "== receipts"
    for f in "$XDG_STATE_HOME"/blackice/scopes/*/receipts.jsonl; do
        [ -f "$f" ] || continue
        echo "-- $(basename "$(dirname "$f")")"
        cat "$f"
    done
}

# file_mode PATH: the permission bits in octal, on Linux and macOS.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
