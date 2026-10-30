#!/bin/bash
# P0-01 (policy before execution) and P0-02 (real deny) on macOS.
# Usage: p0-01-02-macos.sh BLACKICE POLICY SENDER_PY RECEIVER_V4 RECEIVER_V6 WORKDIR
# Start scripts/evidence/offhost-receiver.py on another machine first; it must log the "control" sends and
# nothing from the "scoped" ones. WORKDIR is emptied and used for the copies and the scopes' state.
set -u
[ $# -eq 6 ] || { echo "usage: $0 BLACKICE POLICY SENDER_PY RECEIVER_V4 RECEIVER_V6 WORKDIR" >&2; exit 2; }
V4=$4; V6=$5
W=$6; rm -rf "$W"; mkdir -p "$W"; W=$(cd "$W" && pwd -P)
cp "$1" "$W/blackice"; chmod 755 "$W/blackice"
cp "$3" "$W/sender.py"; cp "$2" "$W/agent.json"
export XDG_STATE_HOME="$W/state"
B="$W/blackice"; P="$W/agent.json"
step() { echo; echo "\$ $*"; }
echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(csrutil status)"
echo "blackice sha256 $(shasum -a 256 "$B" | cut -d' ' -f1)"
echo "policy sha256 $(shasum -a 256 "$P" | cut -d' ' -f1)"
cat "$P"
echo; echo "== P0-02 control: the same sender, NOT in a scope (the receiver must log these)"
step python3 -I sender.py $V4 $V6 control
/usr/bin/python3 -I "$W/sender.py" $V4 $V6 control
echo; echo "== P0-02: the sender inside a scope"
step blackice run --policy agent.json -- /usr/bin/python3 -I sender.py $V4 $V6 scoped
"$B" run --policy "$P" -- /usr/bin/python3 -I "$W/sender.py" $V4 $V6 scoped; echo "exit=$?"
echo; echo "== P0-02: curl inside a scope, direct (--noproxy) and through the scope's proxy"
step blackice run --policy agent.json -- sh -c "curl --noproxy '*' -sS -m 3 http://$V4:47121/; echo curl-direct-v4 exit=\$?; curl --noproxy '*' -sS -m 3 'http://[$V6]:47122/'; echo curl-direct-v6 exit=\$?; curl -sS -m 3 -o /dev/null -w 'via proxy HTTP %{http_code}\n' http://$V4:47121/; curl -sS -m 5 -o /dev/null -w 'example.com HTTP %{http_code}\n' https://example.com"
"$B" run --policy "$P" -- /bin/sh -c "curl --noproxy '*' -sS -m 3 http://$V4:47121/; echo curl-direct-v4 exit=\$?; curl --noproxy '*' -sS -m 3 'http://[$V6]:47122/'; echo curl-direct-v6 exit=\$?; curl -sS -m 3 -o /dev/null -w 'via proxy HTTP %{http_code}\n' http://$V4:47121/; curl -sS -m 5 -o /dev/null -w 'example.com HTTP %{http_code}\n' https://example.com"; echo "exit=$?"
echo; echo "== P0-01: the policy is in place before the command's first instruction"
step blackice run --policy agent.json -- /usr/bin/curl --noproxy '*' -sS -m 3 http://$V4:47121/
"$B" run --policy "$P" -- /usr/bin/curl --noproxy '*' -sS -m 3 http://$V4:47121/; echo "exit=$?"
step 'blackice run -- sh -c "(sleep 1; curl --noproxy * ... ) & wait"   # a grandchild, started later'
"$B" run --policy "$P" -- /bin/sh -c "(sleep 1; /usr/bin/curl --noproxy '*' -sS -m 3 http://$V4:47121/; echo grandchild-curl exit=\$?) & wait"; echo "exit=$?"
printf '{"version":"blackice.policy/v0","network":{"mode":"allowlist","allow":["*"]}}' > "$W/bad.json"
step 'blackice run --policy bad.json -- sh -c "touch started"   # a policy that does not parse'
"$B" run --policy "$W/bad.json" -- /bin/sh -c "touch '$W/started'"; echo "exit=$?"
[ -e "$W/started" ] && echo "the command ran (BAD)" || echo "the command never started: no 'started' file"
step 'blackice run --policy agent.json --policy-sha256 <wrong hash> -- sh -c "touch started2"'
"$B" run --policy "$P" --policy-sha256 0000000000000000000000000000000000000000000000000000000000000000 -- /bin/sh -c "touch '$W/started2'"; echo "exit=$?"
[ -e "$W/started2" ] && echo "the command ran (BAD)" || echo "the command never started: no 'started2' file"
echo; echo "== receipts (all scopes of this run, in order)"
for f in $(ls -tr "$W"/state/blackice/scopes/*/receipts.jsonl); do echo "-- $f"; cat "$f"; done
