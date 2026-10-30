# P0-02: real deny on macOS

**Claim.** A command in a blackice task scope on macOS cannot reach an address outside its scope:
- It cannot open a TCP connection or send a UDP datagram, over IPv4 or IPv6.
- It cannot look up a name.
- It cannot listen.
- It cannot have launchd start a job for it.

Seatbelt refuses each call in the kernel. A receiver on another machine got nothing from inside the
scope, while the same sender reached it from outside, before and after. This covers checkpoint
P0-02 (real deny) for the macOS task scope.

**Platform.** macOS 27.0.1 (26A434), arm64 (MacBook Air), System Integrity Protection enabled.
The receiver ran on a Linux machine on the same LAN (Debian 13, kernel 6.12).

**Build.** `claude/run` at 58e73cc, built with `zig build release` (Zig 0.17.0, ReleaseSafe, stripped,
macOS minimum 13.0). The binary was `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`. The branch now has later commits,
which change output buffering, comments and the proxy's grant watchdog. Their release build has
another hash, and this run did not use it.

**Policy.** `agent.json`, sha256 `b28c9f29dbeafbf9ae0fa9163a3affaefbc997aaedc19c23b3d20bf1dc662760`:

```json
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com", "registry.npmjs.org"]
  }
}
```

**Run.** The scripts are in `scripts/evidence/`.

1. On the Linux machine:
   `python3 -I offhost-receiver.py 192.168.100.40 <its Tailscale IPv6 address> receiver.log 200`.
   It listens on TCP 47121 (IPv4) and 47122 (IPv6), and on UDP 47123 (IPv4) and 47124 (IPv6), and
   logs every connection and datagram.
2. On the Mac:
   `p0-01-02-macos.sh blackice-aarch64-macos agent.json offhost-sender.py 192.168.100.40 <receiver IPv6> /tmp/ns-e2e/run5-p0102`.
   The sender opens one TCP connection and sends one UDP datagram per address family, with its
   label as the payload. The script runs, in order:
   - the sender outside any scope, labeled `control`;
   - the sender in a scope, `blackice run --policy agent.json -- /usr/bin/python3 -I sender.py V4 V6 scoped`;
   - in one scope, four curls:
     - `--noproxy '*'` to each receiver port, direct;
     - one to the IPv4 port through the scope's proxy;
     - one to `https://example.com`;
   - in three scopes:
     - a Python name lookup of `example.com`;
     - a Python `bind` and `listen` on 127.0.0.1;
     - `launchctl submit` of a job that would create a file;
   - the P0-01 runs (see that entry);
   - the sender outside any scope again, labeled `control-after`.

The IPv4 path is the LAN. The IPv6 path goes over Tailscale, because the LAN's global IPv6 addresses
did not reach the receiver even from outside a scope.

**Result.**

| Attempt from inside the scope | What the command saw | Enforcement point |
|---|---|---|
| python3 TCP connect, IPv4 and IPv6 | `scoped tcp4: Operation not permitted`, `scoped tcp6: Operation not permitted` | kernel (Seatbelt) |
| python3 UDP send, IPv4 and IPv6 | `scoped udp4: Operation not permitted`, `scoped udp6: Operation not permitted` | kernel (Seatbelt) |
| curl direct, IPv4 and IPv6 | `curl: (7) Failed to connect to … after 0 ms: Couldn't connect to server` | kernel (Seatbelt) |
| curl to the receiver's IPv4 port through the scope's proxy | `via proxy HTTP 403` | proxy (`port_not_allowed`) |
| curl `https://example.com` (allowed) | `example.com HTTP 200` | proxy (`allowed_by_rule`) |
| Python `getaddrinfo("example.com")` | `lookup failed: [Errno 8] nodename nor servname provided, or not known` | kernel: the connection to the local resolver socket counts as outbound and is refused |
| Python `bind(("127.0.0.1", 0))` + `listen` | `bind/listen failed: [Errno 1] Operation not permitted` | kernel (Seatbelt, `clients_only`) |
| `launchctl submit -l … -- /usr/bin/touch launchd-ran` | launchctl exit 1; no `launchd-ran` file two seconds later | kernel (Seatbelt, `launch_outside_scope`) |

The receiver ran from 07:12:36Z and logged the four `control` sends, then the four `control-after`
sends about ten seconds later. Nothing came from inside a scope. The last line is the P0-07 run's
own control, sent right after. The Mac's Tailscale address is shortened in the log:

```
{"t": 1793344356.6956563, "event": "listening", "v4": "192.168.100.40", "v6": "fd7a:115c:a1e0::…", "ports": {"tcp4": 47121, "tcp6": 47122, "udp4": 47123, "udp6": 47124}}
{"t": 1793344358.683176, "proto": "tcp4", "from": "192.168.100.72", "data": "control-tcp4"}
{"t": 1793344358.6867535, "proto": "udp4", "from": "192.168.100.72", "data": "control-udp4"}
{"t": 1793344358.6868212, "proto": "tcp6", "from": "fd7a:115c:a1e0::…", "data": "control-tcp6"}
{"t": 1793344358.6868412, "proto": "udp6", "from": "fd7a:115c:a1e0::…", "data": "control-udp6"}
{"t": 1793344368.9075012, "proto": "tcp4", "from": "192.168.100.72", "data": "control-after-tcp4"}
{"t": 1793344368.9114227, "proto": "udp4", "from": "192.168.100.72", "data": "control-after-udp4"}
{"t": 1793344368.9115584, "proto": "tcp6", "from": "fd7a:115c:a1e0::…", "data": "control-after-tcp6"}
{"t": 1793344368.9115725, "proto": "udp6", "from": "fd7a:115c:a1e0::…", "data": "control-after-udp6"}
{"t": 1793344373.7573876, "proto": "tcp4", "from": "192.168.100.72", "data": "fx-control-after"}
```

**Receipts.** `scope_start`, `backend_armed` and `scope_end` lines are left out except in the first
scope. Paths are shortened to `…/run5-p0102`.

```
{"ts":"2026-10-30T07:12:38.988Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command python3; proxy port 50509; 2 protected files"}
{"ts":"2026-10-30T07:12:39.087Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=Python pid=10742"}
{"ts":"2026-10-30T07:12:39.087Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47122,"detail":"backend=seatbelt op=network-outbound target=remote:*:47122 process=Python pid=10742"}
{"ts":"2026-10-30T07:12:39.088Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47123,"detail":"backend=seatbelt op=network-outbound target=remote:*:47123 process=Python pid=10742"}
{"ts":"2026-10-30T07:12:39.088Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47124,"detail":"backend=seatbelt op=network-outbound target=remote:*:47124 process=Python pid=10742"}
{"ts":"2026-10-30T07:12:39.101Z","scope":"s-9b7cd52c","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
{"ts":"2026-10-30T07:12:39.130Z","scope":"s-1bf6f7de","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=10748"}
{"ts":"2026-10-30T07:12:39.135Z","scope":"s-1bf6f7de","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47122,"detail":"backend=seatbelt op=network-outbound target=remote:*:47122 process=curl pid=10749"}
{"ts":"2026-10-30T07:12:39.140Z","scope":"s-1bf6f7de","policy":"b28c9f29dbea","gen":1,"point":"proxy","event":"http","verdict":"deny","reason":"port_not_allowed","host":"192.168.100.40","port":47121,"detail":"method=GET"}
{"ts":"2026-10-30T07:12:40.185Z","scope":"s-1bf6f7de","policy":"b28c9f29dbea","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"allowed_by_rule","rule":"example.com","host":"example.com","ip":"2606:4700:10::ac42:93f3","port":443,"detail":"sni_match"}
{"ts":"2026-10-30T07:12:40.408Z","scope":"s-672622d2","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","detail":"backend=seatbelt op=network-outbound target=/private/var/run/mDNSResponder process=Python pid=10757"}
{"ts":"2026-10-30T07:12:40.480Z","scope":"s-506880fd","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"clients_only","port":0,"detail":"backend=seatbelt op=network-bind target=local:*:0 process=Python pid=10762"}
{"ts":"2026-10-30T07:12:40.517Z","scope":"s-5d883e6b","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"launch_outside_scope","detail":"backend=seatbelt op=job-creation target=- process=launchctl pid=10767"}
```

**Recording.** None yet.

**Limits.**
- macOS writes a kernel log line, and blackice turns it into a `kernel_drop` receipt, only for
  refusals of Apple-signed binaries (here `python3`, `curl` and `launchctl`). A refusal of an
  ad-hoc-signed binary is enforced the same way but leaves no receipt. That was tested with blackice
  itself and with a program built with cc. Binaries signed with a third-party Developer ID were not
  tested.
- The kernel prints the remote address as `*`. A `kernel_drop` receipt has the port but not the
  address.
- This run covers TCP connect, UDP send, name lookup, bind/listen and launchd job submission. It does
  not cover raw sockets, ICMP, `open` (LaunchServices) or Apple Events: the profile refuses the last
  two, but testing them opens windows.
- One attempt of each kind. Under a burst, the kernel log loses some lines. The refusals still
  happen, but some receipts are missing.
- The IPv6 control path is Tailscale, not the LAN.
- An earlier run, at 07:02Z, had a proxied `https://example.com` time out. The proxy waits for the
  upstream dial before it answers CONNECT and tries addresses one at a time. A fix is in review. This
  run's request got 200.

**Date.** 30 Oct 2026, 07:12 UTC.
