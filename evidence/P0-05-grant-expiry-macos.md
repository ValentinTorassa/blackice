# P0-05: a grant's expiry cuts the live connection and refuses new ones (macOS)

**Claim.** When an owner grant ends, the proxy resets the connection opened under it within milliseconds. The
stream stops at the expiry, and a new connection to the same name is refused again. Checkpoint P0-05.

**Platform.** macOS 27.0.1 (26A434), arm64 (Apple silicon), SIP enabled.

**Build.** `claude/run` at 58b9491, `zig build release` with Zig 0.17.0 (cross-compiled on Linux; default
`-Dmacos-min=13.0`). Binary `blackice-aarch64-macos`, sha256
`7663b87d11cd9d1da3be3b097e6dac5ebf628c4aea17f2e65e1b91b4f317c929`, checked on the Mac before the run (the
run prints it too).

**Policy.** `policy.json`, id `b0aa1758b9c7`: an allow list with only `example.com` (the same file as P0-03
and P0-04). httpbingo.org is not on it.

```json
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com"]
  }
}
```

**Run.** In `/tmp/ns-net` on the Mac, with `XDG_STATE_HOME=/tmp/ns-net/state-p05b-1793345025`. One scope
runs the bash script below. It waits on its standard input for the owner's go-ahead.

```sh
blackice run --policy policy.json -- /bin/bash -c "$INNER" inner /tmp/ns-net/state-p05b-1793345025.drip
```

The stream is server-paced: httpbingo.org's `/drip` sends its bytes evenly over the time asked for, and curl
`-N` reads each one as it arrives, so nothing waits unread on the client side (see Limits for why that
matters). `/drip` allows at most 10 s per request, so curl asks for six in a row on one connection.

`$INNER`, the scoped command:

```sh
code() { /usr/bin/curl -sS -o /dev/null -m 15 -w "CONNECT %{http_connect}, HTTP %{http_code}" "$1" 2>&1; }
now() { date -u +%H:%M:%SZ; }
echo "inside: $(now) waiting for the owner grant"
read -r _
echo "inside: $(now) httpbingo.org right after the grant -> $(code https://httpbingo.org/get)"
echo "inside: $(now) stream: six 10 s drips of 1000 bytes on one connection (100 bytes/s for 60 s); bytes received so far, every 2 s:"
D="https://httpbingo.org/drip?duration=10&numbytes=1000&delay=0"
/usr/bin/curl -sS -N --fail-early -m 90 -w "\n  [transfer done: HTTP %{http_code}, new connections %{num_connects}]\n" "$D" "$D" "$D" "$D" "$D" "$D" > "$1.out" 2> "$1.err" &
C=$!
body() { grep -v "^  \[transfer done" "$1.out" | tr -d "\n" | wc -c | tr -d " "; }
while kill -0 $C 2> /dev/null; do echo "  $(now) $(body "$1") bytes"; sleep 2; done
wait $C
rc=$?
echo "inside: $(now) stream curl exit $rc after $(body "$1") bytes: $(cat "$1.err")"
grep "^  \[transfer done" "$1.out"
echo "inside: $(now) httpbingo.org again, a new connection -> $(code https://httpbingo.org/get)"
```

The owner, outside the scope, once the scope prints "waiting for the owner grant": `blackice grant s-d0e7b945
httpbingo.org --for 20s`, then one line to the scope's standard input.

**Result.**

Owner, outside the scope:

```
outside: 07:23:45Z $ blackice grant s-d0e7b945 httpbingo.org --for 20s
granted httpbingo.org to scope s-d0e7b945 until 2026-10-30T07:24:05.810Z
outside: grant exit 0
```

Scoped command output (stdout and stderr through a pipe):

```
blackice: scope s-d0e7b945 (policy b0aa1758b9c7, macos-seatbelt); receipts: /tmp/ns-net/state-p05b-1793345025/blackice/scopes/s-d0e7b945/receipts.jsonl
blackice: to allow one more host for a while: blackice grant s-d0e7b945 HOST --for 10m
inside: 07:23:45Z waiting for the owner grant
inside: 07:23:45Z httpbingo.org right after the grant -> CONNECT 200, HTTP 200
inside: 07:23:46Z stream: six 10 s drips of 1000 bytes on one connection (100 bytes/s for 60 s); bytes received so far, every 2 s:
  07:23:46Z 0 bytes
  07:23:48Z 0 bytes
  07:23:50Z 116 bytes
  07:23:52Z 319 bytes
  07:23:54Z 522 bytes
  07:23:56Z 725 bytes
  07:23:58Z 920 bytes
  07:24:00Z 1098 bytes
  07:24:02Z 1302 bytes
  07:24:04Z 1506 bytes
inside: 07:24:06Z stream curl exit 18 after 1637 bytes: curl: (18) Transferred a partial file
  [transfer done: HTTP 200, new connections 1]
  [transfer done: HTTP 200, new connections 0]
inside: 07:24:06Z httpbingo.org again, a new connection -> curl: (56) CONNECT tunnel failed, response 403
CONNECT 403, HTTP 000
blackice: scope s-d0e7b945 ended with status 0; 8 receipts
```

- The grant ran until 07:24:05.810. The proxy's watchdog wrote `grant_expired` (detail `connection_reset`) at
  07:24:05.821, 11 ms later, and reset the tunnel.
- The stream grew by about 100 bytes/s until then and stopped at 1637 bytes. The first drip had finished (1000
  bytes, one new connection). The second, on the same connection ("new connections 0"), was cut after 637 of
  its 1000 bytes. curl exited 18 ("Transferred a partial file"): the connection ended in the middle of a body.
- The next connection to httpbingo.org, at 07:24:06.572, was refused with 403 and reason `no_matching_rule`:
  without the grant the policy applies again.

Enforcement point: the proxy. The grant lives in its grant table on the boot clock. The watchdog task opened
with the connection compares the grant's end with the boot clock at least every 200 ms, then resets both sides
of the tunnel (`SO_LINGER` 0, then shutdown). New connections are decided against the policy alone once the
grant has ended.

**Receipts.** `s-d0e7b945`, verbatim:

```
{"ts":"2026-10-30T07:23:45.523Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command bash; proxy port 51321; 3 protected files"}
{"ts":"2026-10-30T07:23:45.537Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T07:23:45.810Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"grant","verdict":"allow","reason":"owner_grant","rule":"httpbingo.org","host":"httpbingo.org","detail":"pid=11889 for 20s until 2026-10-30T07:24:05.810Z"}
{"ts":"2026-10-30T07:23:45.883Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"granted","rule":"grant:httpbingo.org","host":"httpbingo.org","ip":"2a09:8280:1:7fcb:9efa:a365:aa2a:d036","port":443,"detail":"sni_match grant_until=2026-10-30T07:24:05.810Z"}
{"ts":"2026-10-30T07:23:48.460Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"granted","rule":"grant:httpbingo.org","host":"httpbingo.org","ip":"2a09:8280:1:7fcb:9efa:a365:aa2a:d036","port":443,"detail":"sni_match grant_until=2026-10-30T07:24:05.810Z"}
{"ts":"2026-10-30T07:24:05.821Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"grant_expired","host":"httpbingo.org","detail":"connection_reset"}
{"ts":"2026-10-30T07:24:06.572Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"httpbingo.org","port":443}
{"ts":"2026-10-30T07:24:06.592Z","scope":"s-d0e7b945","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

The second `connect` receipt is the stream's tunnel. A CONNECT receipt is written once the first TLS bytes
pass the server-name check.

**Follow-up check: bytes already in the client's buffer.** 07:24 UTC, same Mac and build, scope `s-d2cef96e`.
The same 20 s grant (github.com), but with a client that reads slowly: `curl --limit-rate 2000 -m 45
https://github.com/torvalds/linux`. Outside the scope, `netstat -an -p tcp` sampled the sockets on the proxy
port (51473) every 3 s. Excerpt (proxy side first, curl's side second):

```
-- 07:24:55Z
tcp4       0      0  127.0.0.1.51473        127.0.0.1.51476        ESTABLISHED
tcp4  277807      0  127.0.0.1.51476        127.0.0.1.51473        ESTABLISHED
-- 07:25:10Z
tcp4       0      0  127.0.0.1.51473        127.0.0.1.51476        ESTABLISHED
tcp4  244933      0  127.0.0.1.51476        127.0.0.1.51473        ESTABLISHED
-- 07:25:13Z
tcp4       0      0  127.0.0.1.51473        *.*                    LISTEN
```

```
{"ts":"2026-10-30T07:25:11.799Z","scope":"s-d2cef96e","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"grant_expired","host":"github.com","detail":"connection_reset"}
```

Three seconds into the download, 277,807 bytes were already in curl's socket receive buffer (Recv-Q), and
nothing was queued in the proxy (Send-Q 0). At the first sample after the expiry (07:25:11.789, receipt at
.799) both sockets of the tunnel were gone. curl still went on reading what its buffer held at 2000 bytes/s and
ended on its own 45 s timeout with 98,295 bytes (exit 28). Nothing crossed the proxy after the expiry. The
bytes curl read later had reached its buffer in the first seconds of the grant.

**Recording.** None for this run.

**Limits.**
- Bytes that reach the client's socket buffer before the expiry stay readable after it: macOS let curl go on
  reading its socket's buffered data after the tunnel was reset, and no action by the proxy can take that data
  back. For a client that reads slowly, this can be hundreds of kilobytes (follow-up check). The cut is at the proxy. It is
  not at the moment the client reads.
- curl reports the cut as an end of stream in the middle of a body (exit 18), not as a reset error. The
  proxy's shutdown sends a FIN before its linger-0 close resets, and curl reads the FIN first. The receipt's
  `connection_reset` describes what the proxy does.
- The watchdog wakes at least every 200 ms; here it acted 11 ms after the end (10 ms in the follow-up check).
- Revoking a grant and a plain HTTP exchange cut by an expiry are covered by the proxy's unit tests, and
  extending a grant by the grant table's tests. This run shows none of them.
- httpbingo.org is a public test service. Its `/drip` endpoint paced the stream.
- One run, by the person who built it. Not a recording.

**Date.** 2026-10-30, 07:23 UTC.
