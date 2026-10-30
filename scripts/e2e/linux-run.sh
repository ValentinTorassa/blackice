#!/usr/bin/env bash
# blackice end to end on Linux: one scope per command, real commands, real network, receipts.
#
# The same checks as the macOS run (allowed names through the proxy, denied names, direct connections, the
# metadata address, the clean environment, receipts the scope cannot change), plus two Linux-only checks:
# an unconnected UDP sendto and a ping from inside the scope, both refused by the kernel with receipts.
#
# Needs: a built blackice whose `run` launches the Linux backend, and the helper the owner installed with
# scripts/linux-setup.sh. This script never installs anything and never uses sudo. Synthetic policy; the only
# "secrets" are synthetic values it sets itself to show they do not reach the scope.
#
# Usage: scripts/e2e/linux-run.sh        (BLACKICE=/path/to/blackice, E2E_DIR=/path/to/empty/dir optional)
set -u
. "$(dirname "$0")/lib.sh"

[ "$(uname -s)" = Linux ] || die "this script is for Linux"
command -v python3 > /dev/null || die "python3 is needed (UDP probe and receipt checks)"
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

# Values that must not reach the scope. Synthetic.
export E2E_FAKE_SECRET=synthetic-e2e-value
export AWS_SECRET_ACCESS_KEY=synthetic-not-a-real-key
export GITHUB_TOKEN=synthetic-not-a-real-token

# 0. The backend must really be the Linux one; otherwise nothing below means anything.
scoped probe -- /bin/true
if [ "$RC" -ne 0 ] || [ -z "$SID" ]; then
    die "blackice run could not start a scope here (exit $RC); see $ERR"
fi
check "the Linux backend armed the scope (kernel backend_armed receipt)" \
    has_receipt "$RCPT" point=kernel event=backend_armed
FIRST_RCPT=$RCPT

# 1. Allowed names go through the proxy.
scoped example -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://example.com
check "example.com through the proxy: HTTP 2xx/3xx" grep -Eq '^[23][0-9][0-9]$' "$OUT"
check "example.com: proxy allow receipt" has_receipt "$RCPT" point=proxy event=connect verdict=allow host=example.com

scoped npm -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://registry.npmjs.org/left-pad
check "registry.npmjs.org through the proxy: HTTP 2xx/3xx" grep -Eq '^[23][0-9][0-9]$' "$OUT"
check "registry.npmjs.org: proxy allow receipt" has_receipt "$RCPT" point=proxy verdict=allow host=registry.npmjs.org

# 2. A name the policy does not list: the proxy answers 403 to the CONNECT.
scoped github -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_connect}' https://github.com
check "github.com: refused (CONNECT 403, curl fails)" sh -c "[ $RC -ne 0 ] && grep -q 403 '$OUT'"
check "github.com: proxy deny receipt" has_receipt "$RCPT" point=proxy verdict=deny host=github.com

# 3. Going around the proxy: the kernel refuses the connection (by name, DNS is refused first).
scoped direct-name -- /usr/bin/curl -sS -m 8 --noproxy '*' -o /dev/null https://example.com
check "direct https://example.com with --noproxy: fails" test "$RC" -ne 0
check "direct by name: kernel_drop receipt" has_receipt "$RCPT" point=kernel event=kernel_drop verdict=deny

scoped direct-ip -- /usr/bin/curl -sS -m 8 --noproxy '*' -o /dev/null https://1.1.1.1
check "direct https://1.1.1.1 with --noproxy: fails" test "$RC" -ne 0
check "direct 1.1.1.1:443: kernel_drop receipt" has_receipt "$RCPT" point=kernel event=kernel_drop ip=1.1.1.1 port=443

# 4. The cloud metadata address: refused by the proxy (link-local literal) and by the kernel (direct).
scoped metadata -- /usr/bin/curl -sS -m 8 -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/
check "169.254.169.254 through the proxy: HTTP 403" grep -q '^403$' "$OUT"
check "169.254.169.254: proxy deny receipt" has_receipt "$RCPT" point=proxy verdict=deny line~169.254.169.254

scoped metadata-direct -- /usr/bin/curl -sS -m 5 --noproxy '*' -o /dev/null http://169.254.169.254/latest/meta-data/
check "169.254.169.254 direct: fails" test "$RC" -ne 0
check "169.254.169.254 direct: kernel_drop receipt" has_receipt "$RCPT" point=kernel event=kernel_drop ip=169.254.169.254

# 5. The scope gets a clean environment: blackice's variables, not the caller's secrets.
scoped env -- /bin/sh -c 'env | sort | grep -E "^(BLACKICE|HTTPS?_PROXY|NO_PROXY|AWS|GITHUB)"; echo "secret-in-parent=${E2E_FAKE_SECRET:-absent}"'
check "environment: BLACKICE_SCOPE and HTTPS_PROXY set" sh -c "grep -q '^BLACKICE_SCOPE=s-' '$OUT' && grep -q '^HTTPS_PROXY=http://127.0.0.1:' '$OUT'"
check "environment: caller's secrets absent" sh -c "grep -q '^secret-in-parent=absent$' '$OUT' && ! grep -Eq '^(AWS|GITHUB)' '$OUT'"

# 6. Receipts: the scope can read where they are, but cannot add to its own or to another scope's.
scoped forge -- /bin/sh -c 'own="$XDG_STATE_HOME/blackice/scopes/$BLACKICE_SCOPE/receipts.jsonl"
    for f in "$own" "$1"; do if echo forged-by-scope >> "$f" 2> /dev/null; then echo "WROTE $f"; else echo "refused: $f"; fi; done' sh "$FIRST_RCPT"
check "forged receipts: no write reported from inside" sh -c "! grep -q '^WROTE' '$OUT'"
check "forged receipts: no forged line in any receipts file" sh -c "! grep -l forged-by-scope '$XDG_STATE_HOME'/blackice/scopes/*/receipts.jsonl"

# 7. Linux only: an unconnected UDP sendto, to a local receiver outside the scope and to a public resolver.
python3 -I - "$W/udp-port" "$W/udp-count" 20 > /dev/null 2>&1 <<'PY' &
import os, socket, sys, time
# Counts datagrams on a loopback port until told to stop (or for at most N seconds).
port_file, count_file, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
with open(port_file + ".tmp", "w") as f:
    f.write(str(s.getsockname()[1]))
os.replace(port_file + ".tmp", port_file)
s.settimeout(0.2)
n, end = 0, time.monotonic() + seconds
while time.monotonic() < end and not os.path.exists(count_file + ".stop"):
    try:
        s.recvfrom(2048)
        n += 1
    except socket.timeout:
        pass
with open(count_file, "w") as f:
    f.write(str(n))
PY
RECEIVER=$!
for _ in $(seq 1 50); do [ -s "$W/udp-port" ] && break; sleep 0.1; done
UDP_PORT=$(cat "$W/udp-port" 2> /dev/null)
[ -n "$UDP_PORT" ] || die "the local UDP receiver did not start"
scoped udp -- /usr/bin/python3 -I -c '
import errno, socket, sys
for host, port in (("127.0.0.1", int(sys.argv[1])), ("1.1.1.1", 53)):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.sendto(b"blackice-e2e", (host, port))
        print("sent %s:%d" % (host, port))
    except OSError as e:
        print("refused %s:%d %s" % (host, port, errno.errorcode.get(e.errno, e.errno)))
' "$UDP_PORT"
sleep 1
touch "$W/udp-count.stop"
wait "$RECEIVER" 2> /dev/null
check "UDP sendto 127.0.0.1:$UDP_PORT from inside: refused with EPERM" grep -q "^refused 127.0.0.1:$UDP_PORT EPERM$" "$OUT"
check "UDP sendto 1.1.1.1:53 from inside: refused with EPERM" grep -q '^refused 1.1.1.1:53 EPERM$' "$OUT"
check "UDP: the receiver outside got nothing" test "$(cat "$W/udp-count" 2> /dev/null || echo 0)" = 0
check "UDP to 127.0.0.1:$UDP_PORT: kernel_drop receipt (protocol 17)" \
    has_receipt "$RCPT" point=kernel event=kernel_drop port="$UDP_PORT" detail~protocol=17
check "UDP to 1.1.1.1:53: kernel_drop receipt" has_receipt "$RCPT" point=kernel event=kernel_drop ip=1.1.1.1 port=53

# 8. Linux only: ping (ICMP) from inside. A literal address, so no DNS: any kernel denial here is the ping.
scoped ping -- /usr/bin/ping -n -c 1 -W 2 1.1.1.1
check "ping 1.1.1.1 from inside: refused (Operation not permitted)" \
    sh -c "[ $RC -ne 0 ] && grep -qi 'operation not permitted' '$OUT' '$ERR'"
check "ping: kernel deny receipt" has_receipt "$RCPT" point=kernel verdict=deny

# 9. Every scope ends with scope_end, and the state is owner-only.
ok=true
for f in "$XDG_STATE_HOME"/blackice/scopes/*/receipts.jsonl; do ends_with_scope_end "$f" || { ok=false; echo "  no final scope_end in $f"; }; done
check "every scope's last receipt is scope_end" $ok
SCOPE_DIR=$(dirname "$FIRST_RCPT")
echo
echo "== modes"
for p in "$XDG_STATE_HOME/blackice" "$XDG_STATE_HOME/blackice/scopes" "$SCOPE_DIR" "$FIRST_RCPT" "$SCOPE_DIR/policy.json"; do
    [ -e "$p" ] && echo "  $(file_mode "$p") $p"
done
check "scope directory is 700" test "$(file_mode "$SCOPE_DIR")" = 700
check "receipts file is 600" test "$(file_mode "$FIRST_RCPT")" = 600

show_receipts
summary
