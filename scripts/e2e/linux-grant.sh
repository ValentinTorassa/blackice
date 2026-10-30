#!/usr/bin/env bash
# blackice grants on Linux: the owner grants and revokes a name from outside a running scope; the scope
# cannot grant itself, a grant covers one exact name, and nothing reaches a scope that has ended.
#
# The scoped command is one bash script. It waits on its stdin (a FIFO this script holds) for the owner's
# go-ahead, so the order is fixed: check, owner grants, check, owner revokes, check.
#
# Needs: a built blackice whose `run` launches the Linux backend, and the helper the owner installed with
# scripts/linux-setup.sh. Never installs anything, never uses sudo. Synthetic policy, no credentials.
#
# Usage: scripts/e2e/linux-grant.sh      (BLACKICE=/path/to/blackice, E2E_DIR=/path/to/empty/dir optional)
set -u
. "$(dirname "$0")/lib.sh"

[ "$(uname -s)" = Linux ] || die "this script is for Linux"
command -v python3 > /dev/null || die "python3 is needed (receipt checks)"
command -v curl > /dev/null || die "curl is needed"
e2e_blackice
HELPER=/usr/local/libexec/blackice-linux-helper
[ -e "$HELPER" ] || die "the Linux helper is not installed at $HELPER (the owner runs scripts/linux-setup.sh)"
e2e_workdir
e2e_policy

. /etc/os-release 2> /dev/null
echo "== Linux $(uname -r) ($(uname -m)), ${PRETTY_NAME:-unknown distribution}"
echo "== $("$B" version); helper $(ls -l "$HELPER" | awk '{print $1, $3, $4}')"
echo "== work dir $W"

# The backend must start a scope here; otherwise nothing below means anything.
scoped probe -- /bin/true
[ "$RC" -eq 0 ] && [ -n "$SID" ] || die "blackice run could not start a scope here (exit $RC); see $ERR"

# A copy of blackice in the scope's working directory, so the self-grant below fails because of the scope,
# not because the binary is out of sight.
cp "$B" "$W/blackice-copy" && chmod 700 "$W/blackice-copy"

INNER='
code() { /usr/bin/curl -sS -o /dev/null -m 10 -w "%{http_connect}/%{http_code}" "$1" 2> /dev/null; }
echo "inside: github.com before the grant -> $(code https://github.com)"
"$1" grant "$BLACKICE_SCOPE" github.com --for 5m
echo "inside: self-grant exit $?"
echo "inside: waiting for the owner grant"
read -r _
echo "inside: github.com after the owner grant -> $(code https://github.com)"
echo "inside: www.github.com (not granted) -> $(code https://www.github.com)"
echo "inside: waiting for the owner revoke"
read -r _
echo "inside: github.com after the revoke -> $(code https://github.com)"
'

LOG="$W/out/grant-run.log"
mkfifo "$W/owner" || die "mkfifo failed"
exec 3<> "$W/owner"
echo
echo "\$ blackice run --policy agent.json -- /bin/bash -c INNER inner ./blackice-copy   (stdin: the owner's FIFO)"
# Through a pipe, not straight into the file (some builds write their own lines at fixed file offsets).
# RUN is the pipe's reader, which ends when the run does; the run's exit status goes to a file.
{ "$B" run --policy "$POLICY" -- /bin/bash -c "$INNER" inner "$W/blackice-copy" < "$W/owner" 2>&1; echo $? > "$W/out/grant-run.rc"; } | cat > "$LOG" &
RUN=$!

# wait_for TEXT: waits up to 60 s for a line in the run's output.
wait_for() {
    local i
    for i in $(seq 1 240); do
        grep -qF "$1" "$LOG" 2> /dev/null && return 0
        kill -0 "$RUN" 2> /dev/null || { grep -qF "$1" "$LOG"; return; }
        sleep 0.25
    done
    return 1
}

if ! wait_for "inside: waiting for the owner grant" || ! scope_of "$LOG"; then
    echo go >&3
    echo go >&3
    wait "$RUN"
    sed 's/^/  | /' "$LOG"
    die "the scoped command did not start or did not reach its first wait"
fi
echo "outside: blackice grant $SID github.com --for 2m"
GRANT_OUT=$("$B" grant "$SID" github.com --for 2m 2>&1)
GRANT_RC=$?
echo "  | $GRANT_OUT"
echo go >&3
wait_for "inside: waiting for the owner revoke" || fail "the scoped command did not reach its second wait"
echo "outside: blackice revoke $SID github.com"
REVOKE_OUT=$("$B" revoke "$SID" github.com 2>&1)
REVOKE_RC=$?
echo "  | $REVOKE_OUT"
echo go >&3
wait "$RUN"
RC=$(cat "$W/out/grant-run.rc" 2> /dev/null || echo 255)
exec 3>&-
echo
echo "== scoped command output"
sed 's/^/  | /' "$LOG"
echo "  [run exit $RC]"
echo "outside: blackice grant $SID github.com --for 1m   (after the scope ended)"
LATE_OUT=$("$B" grant "$SID" github.com --for 1m 2>&1)
LATE_RC=$?
echo "  | $LATE_OUT"
echo
RCPT="$XDG_STATE_HOME/blackice/scopes/$SID/receipts.jsonl"
self_grant_refused() { grep -q 'self-grant exit 1$' "$LOG" && grep -q 'cannot reach the control socket' "$LOG"; }
owner_granted() { [ "$GRANT_RC" -eq 0 ] && printf '%s\n' "$GRANT_OUT" | grep -q '^granted github.com'; }
owner_revoked() { [ "$REVOKE_RC" -eq 0 ] && printf '%s\n' "$REVOKE_OUT" | grep -q '^revoked github.com'; }

check "the Linux backend armed the scope" has_receipt "$RCPT" point=kernel event=backend_armed
check "run exit 0" test "$RC" -eq 0
check "inside, before any grant: github.com refused (CONNECT 403)" grep -q 'github.com before the grant -> 403/' "$LOG"
check "inside: the self-grant fails (exit 1, control socket unreachable)" self_grant_refused
check "outside: the owner grant succeeds" owner_granted
check "inside, after the owner grant: github.com through (CONNECT 200)" grep -Eq 'github.com after the owner grant -> 200/[23]' "$LOG"
check "inside: www.github.com still refused (a grant is one exact name)" grep -q 'www.github.com (not granted) -> 403/' "$LOG"
check "outside: the owner revoke succeeds" owner_revoked
check "inside, after the revoke: github.com refused again" grep -q 'github.com after the revoke -> 403/' "$LOG"
check "outside: a grant after the scope ended fails" test "$LATE_RC" -ne 0

check "receipt: exactly one grant, from the owner" test "$(rq "$RCPT" point=control event=grant)" -eq 1
check "receipt: the owner grant (owner_grant, github.com)" \
    has_receipt "$RCPT" point=control event=grant verdict=allow reason=owner_grant host=github.com
check "receipt: the owner revoke (owner_revoke, removed)" \
    has_receipt "$RCPT" point=control event=revoke reason=owner_revoke detail~removed
check "receipt: github.com allowed by the grant (rule grant:...)" \
    has_receipt "$RCPT" point=proxy verdict=allow host=github.com rule~grant:
check "receipt: github.com refused before the grant and after the revoke" \
    test "$(rq "$RCPT" point=proxy verdict=deny host=github.com)" -ge 2
check "receipt: www.github.com refused" has_receipt "$RCPT" point=proxy verdict=deny host=www.github.com
check "the scope's last receipt is scope_end" ends_with_scope_end "$RCPT"

show_receipts
summary
