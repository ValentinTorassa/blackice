#!/usr/bin/env bash
# blackice real deny on Linux, seen from another machine: a receiver on a second host logs every TCP
# connection and UDP datagram it gets. The same sender runs once outside any scope (the control, which the
# receiver must log) and once inside a scope (which it must not log), over IPv4 and IPv6.
#
# The receiver is started over SSH on the other host (python3 needed there; nothing is installed). It listens
# on TCP 47121/47122 and UDP 47123/47124 (IPv4/IPv6), the same ports as the macOS P0-02 run, and writes JSON
# lines to a log file on that host, which this script reads back. The log is made with mktemp under umask 077,
# so no other user there can create, read or truncate it. A second control after the scoped runs shows the
# receiver was still listening while they ran.
#
# Needs: a built blackice whose `run` launches the Linux backend, the helper installed by the owner, python3
# on both hosts. Synthetic policy, no credentials. Never installs anything, never uses sudo.
#
# Usage: E2E_SSH='ssh -o BatchMode=yes valen@other-host' scripts/e2e/linux-offhost.sh RECEIVER_V4 RECEIVER_V6
#   RECEIVER_V4, RECEIVER_V6  the other host's addresses, as this machine reaches them
#   E2E_SSH                   the ssh command (with options) that reaches the other host
#   E2E_REMOTE_DIR            the directory for the receiver's log on the other host (default /tmp)
set -u
. "$(dirname "$0")/lib.sh"

[ "$(uname -s)" = Linux ] || die "this script is for Linux"
[ $# -eq 2 ] || die "usage: E2E_SSH='ssh ... user@host' $0 RECEIVER_V4 RECEIVER_V6"
[ -n "${E2E_SSH:-}" ] || die "set E2E_SSH to the ssh command that reaches the receiver's host"
command -v python3 > /dev/null || die "python3 is needed"
V4=$1
V6=$2
# Both addresses go into a remote command line, so they must be plain addresses of the right family.
python3 -I -c 'import ipaddress, sys; assert ipaddress.ip_address(sys.argv[1]).version == 4 and ipaddress.ip_address(sys.argv[2]).version == 6' "$V4" "$V6" 2> /dev/null ||
    die "RECEIVER_V4 must be an IPv4 address and RECEIVER_V6 an IPv6 address (got '$V4' '$V6')"
REMOTE_DIR=${E2E_REMOTE_DIR:-/tmp}
case "$REMOTE_DIR" in
    /*) ;;
    *) die "E2E_REMOTE_DIR must be an absolute path" ;;
esac
case "$REMOTE_DIR" in
    *[!A-Za-z0-9/._-]*) die "E2E_REMOTE_DIR may hold only letters, digits and / . _ -" ;;
esac
e2e_blackice
HELPER=/usr/local/libexec/blackice-linux-helper
[ -e "$HELPER" ] || die "the Linux helper is not installed at $HELPER (the owner runs scripts/linux-setup.sh)"
e2e_workdir
e2e_policy
TAG=$(date -u +%Y%m%dT%H%M%SZ)
# A fresh log file only this user can open: mktemp creates it (O_EXCL, unpredictable name), umask 077 makes it 0600.
REMOTE_LOG=$($E2E_SSH "umask 077; mktemp '$REMOTE_DIR/blackice-offhost.XXXXXXXX'" 2> "$W/out/mktemp.err") ||
    { cat "$W/out/mktemp.err"; die "could not create the receiver's log on the other host"; }
case "$REMOTE_LOG" in
    "$REMOTE_DIR"/blackice-offhost.*) ;;
    *) die "unexpected log path from the other host: $REMOTE_LOG" ;;
esac
case "$REMOTE_LOG" in
    *[!A-Za-z0-9/._-]*) die "unexpected log path from the other host: $REMOTE_LOG" ;;
esac

. /etc/os-release 2> /dev/null
echo "== Linux $(uname -r) ($(uname -m)), ${PRETTY_NAME:-unknown distribution}"
echo "== $("$B" version); helper $(ls -l "$HELPER" | awk '{print $1, $3, $4}')"
echo "== receiver $V4 / $V6 via: $E2E_SSH; log $REMOTE_LOG"
echo "== work dir $W"

cat > "$W/receiver.py" <<'PY'
"""Logs every TCP connection and UDP datagram it gets. Usage: receiver.py V4 V6 LOGFILE SECONDS"""
import json, select, socket, sys, time
PORTS = {"tcp4": 47121, "tcp6": 47122, "udp4": 47123, "udp6": 47124}
v4, v6, logpath, seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
socks = []
for name, port in PORTS.items():
    fam = socket.AF_INET if name.endswith("4") else socket.AF_INET6
    typ = socket.SOCK_STREAM if name.startswith("tcp") else socket.SOCK_DGRAM
    s = socket.socket(fam, typ)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((v4 if fam == socket.AF_INET else v6, port))
    if typ == socket.SOCK_STREAM:
        s.listen(16)
    socks.append((name, s))
with open(logpath, "a") as out:
    out.write(json.dumps({"t": time.time(), "event": "listening", "v4": v4, "v6": v6, "ports": PORTS}) + "\n")
    out.flush()
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([s for _, s in socks], [], [], 0.5)
        for s in ready:
            name = next(n for n, x in socks if x is s)
            if name.startswith("tcp"):
                c, addr = s.accept()
                c.settimeout(1)
                try:
                    data = c.recv(256)
                except OSError:
                    data = b""
                c.close()
            else:
                data, addr = s.recvfrom(256)
            out.write(json.dumps({"t": time.time(), "proto": name, "from": addr[0], "data": data.decode(errors="replace")}) + "\n")
            out.flush()
    out.write(json.dumps({"t": time.time(), "event": "stopped"}) + "\n")
PY
cat > "$W/sender.py" <<'PY'
"""One TCP connection and one UDP datagram per address family. Usage: sender.py V4 V6 LABEL"""
import socket, sys
v4, v6, label = sys.argv[1], sys.argv[2], sys.argv[3]
for name, fam, typ, addr, port in [("tcp4", socket.AF_INET, socket.SOCK_STREAM, v4, 47121),
                                   ("tcp6", socket.AF_INET6, socket.SOCK_STREAM, v6, 47122),
                                   ("udp4", socket.AF_INET, socket.SOCK_DGRAM, v4, 47123),
                                   ("udp6", socket.AF_INET6, socket.SOCK_DGRAM, v6, 47124)]:
    s = socket.socket(fam, typ)
    s.settimeout(3)
    try:
        if typ == socket.SOCK_STREAM:
            s.connect((addr, port))
            s.sendall(("%s-%s" % (label, name)).encode())
        else:
            s.sendto(("%s-%s" % (label, name)).encode(), (addr, port))
        print("%s %s: sent" % (label, name))
    except OSError as e:
        print("%s %s: %s" % (label, name, e.strerror or e))
    finally:
        s.close()
PY

# The receiver, on the other host, for 90 s. Its code goes over the ssh connection's stdin.
$E2E_SSH "python3 -I - '$V4' '$V6' '$REMOTE_LOG' 90" < "$W/receiver.py" > "$W/out/receiver.err" 2>&1 &
RECEIVER=$!
remote_log() { $E2E_SSH "cat '$REMOTE_LOG' 2> /dev/null" 2> /dev/null; }
for _ in $(seq 1 40); do remote_log | grep -q '"event": "listening"' && break; sleep 0.5; done
remote_log | grep -q '"event": "listening"' || { cat "$W/out/receiver.err"; die "the receiver did not start on the other host"; }

CONTROL=control-$TAG
SCOPED=scoped-$TAG
echo
echo "\$ python3 -I sender.py $V4 $V6 $CONTROL      # outside any scope: the receiver must log these"
python3 -I "$W/sender.py" "$V4" "$V6" "$CONTROL" | sed 's/^/  | /'

scoped sender -- /usr/bin/python3 -I "$W/sender.py" "$V4" "$V6" "$SCOPED"
SENDER_RCPT=$RCPT
scoped curl -- /bin/sh -c "/usr/bin/curl --noproxy '*' -sS -m 3 http://$V4:47121/$SCOPED-curl4; echo curl-direct-v4 exit=\$?
    /usr/bin/curl --noproxy '*' -sS -m 3 'http://[$V6]:47122/$SCOPED-curl6'; echo curl-direct-v6 exit=\$?
    /usr/bin/curl -sS -m 5 -o /dev/null -w 'through the proxy: HTTP %{http_code}\n' http://$V4:47121/$SCOPED-proxy"
CURL_RCPT=$RCPT
scoped late -- /bin/sh -c "(sleep 1; /usr/bin/python3 -I '$W/sender.py' '$V4' '$V6' '$SCOPED-grandchild') & wait"
LATE_RCPT=$RCPT

AFTER=control-after-$TAG
echo
echo "\$ python3 -I sender.py $V4 $V6 $AFTER      # outside any scope again: the receiver must still log these"
python3 -I "$W/sender.py" "$V4" "$V6" "$AFTER" | sed 's/^/  | /'

sleep 2
remote_log > "$W/out/receiver.jsonl"
kill "$RECEIVER" 2> /dev/null
echo
echo "== receiver log ($REMOTE_LOG on the other host)"
sed 's/^/  | /' "$W/out/receiver.jsonl"
echo

logged() { grep -F "\"data\": \"$1" "$W/out/receiver.jsonl" > /dev/null; }
nothing_scoped() { ! grep -F "$SCOPED" "$W/out/receiver.jsonl" > /dev/null; }
drop() { has_receipt "$1" event=kernel_drop verdict=deny "${@:2}"; }
sender_v4_drops() { drop "$SENDER_RCPT" ip="$V4" port=47121 && drop "$SENDER_RCPT" ip="$V4" port=47123; }
sender_v6_drops() { drop "$SENDER_RCPT" port=47122 && drop "$SENDER_RCPT" port=47124; }
# Exit 7 is "could not connect". Any other failure (52, empty reply) would mean the connection was made.
curl_direct_failed() { grep -q 'curl-direct-v4 exit=7$' "$W/out/curl.out" && grep -q 'curl-direct-v6 exit=7$' "$W/out/curl.out"; }

for p in tcp4 udp4 tcp6 udp6; do
    check "control $p: the receiver logged it (the path works)" logged "$CONTROL-$p"
done
for p in tcp4 udp4 tcp6 udp6; do
    check "control after the scoped runs, $p: logged (the receiver was listening throughout)" logged "$AFTER-$p"
done
check "the receiver logged nothing from any scope" nothing_scoped
for p in tcp4 udp4 tcp6 udp6; do
    check "scoped sender $p: refused inside the scope" grep -Eq "^$SCOPED $p: (Operation not permitted|Permission denied)$" "$W/out/sender.out"
done
check "scoped sender: kernel_drop receipts for $V4:47121 (TCP) and :47123 (UDP)" sender_v4_drops
check "scoped sender: kernel_drop receipts for IPv6 ports 47122 (TCP) and 47124 (UDP)" sender_v6_drops
check "scoped curl --noproxy to both addresses: cannot connect (exit 7)" curl_direct_failed
check "scoped curl through the proxy to the bare address: HTTP 403" grep -q 'through the proxy: HTTP 403' "$W/out/curl.out"
check "a grandchild started 1 s later is refused too" grep -Eq "^$SCOPED-grandchild tcp4: (Operation not permitted|Permission denied)$" "$W/out/late.out"

show_receipts
summary
