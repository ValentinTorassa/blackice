# P0-02: real deny on macOS

**Claim.** A command in a blackice task scope on macOS cannot open a TCP connection or send a UDP
datagram to an address outside its scope, over IPv4 or IPv6. Seatbelt refuses the call in the
kernel, and a receiver on another machine got nothing from inside the scope, while the same sender
reached it from outside. Checkpoint P0-02 (real deny), macOS task scope.

**Platform.** macOS 27.0.1 (26A434), arm64 (MacBook Air), System Integrity Protection enabled.
The receiver ran on a Linux machine on the same LAN (Debian 13, kernel 6.12).

**Build.** `claude/run` at 58e73cc, built with `zig build release` (Zig 0.17.0, ReleaseSafe,
stripped, macOS minimum 13.0). The binary was `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`.

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
   `python3 -I offhost-receiver.py 192.168.100.40 <its Tailscale IPv6 address> receiver.log 120`.
   The receiver listens on TCP 47121 (IPv4) and 47122 (IPv6), and on UDP 47123 (IPv4) and
   47124 (IPv6). It logs every connection and datagram.
2. On the Mac:
   `p0-01-02-macos.sh blackice-aarch64-macos agent.json offhost-sender.py 192.168.100.40 <receiver IPv6> /tmp/ns-e2e/evidence-run`.
   The sender opens one TCP connection and sends one UDP datagram per address family. The payload
   is its label, `control` or `scoped`. The script runs:
   - `python3 -I sender.py V4 V6 control`, outside any scope;
   - `blackice run --policy agent.json -- /usr/bin/python3 -I sender.py V4 V6 scoped`;
   - `blackice run --policy agent.json -- /bin/sh -c "<four curls>"`. The four are:
     - curl `--noproxy '*'` to the receiver's IPv4 port, direct;
     - curl `--noproxy '*'` to the receiver's IPv6 port, direct;
     - curl to the IPv4 port through the scope's proxy (the default inside a scope);
     - `https://example.com` through the proxy.

The IPv4 path is the LAN. The IPv6 path goes over Tailscale, because the LAN's global IPv6
addresses did not reach the receiver even from outside a scope, so they could not serve as a
control.

**Result.**

| Send | Outside a scope | Inside a scope | Enforcement point |
|---|---|---|---|
| python3 TCP, IPv4 | received (`control-tcp4`) | `Operation not permitted` | kernel (Seatbelt) |
| python3 TCP, IPv6 | received (`control-tcp6`) | `Operation not permitted` | kernel (Seatbelt) |
| python3 UDP, IPv4 | received (`control-udp4`) | `Operation not permitted` | kernel (Seatbelt) |
| python3 UDP, IPv6 | received (`control-udp6`) | `Operation not permitted` | kernel (Seatbelt) |
| curl direct, IPv4 | | exit 7, "Couldn't connect to server" after 0 ms | kernel (Seatbelt) |
| curl direct, IPv6 | | exit 7, "Couldn't connect to server" after 0 ms | kernel (Seatbelt) |
| curl through the proxy to the IPv4 port | | HTTP 403 | proxy (`port_not_allowed`) |
| curl `https://example.com` | | HTTP 200 | proxy (`allowed_by_rule`) |

The receiver ran for 120 seconds and logged exactly the four `control` sends. Nothing arrived from
the scoped runs. Log, with the Mac's Tailscale address shortened:

```
{"t": 1793343326.4362423, "event": "listening", "v4": "192.168.100.40", "v6": "fd7a:115c:a1e0::…", "ports": {"tcp4": 47121, "tcp6": 47122, "udp4": 47123, "udp6": 47124}}
{"t": 1793343328.0173686, "proto": "tcp4", "from": "192.168.100.72", "data": "control-tcp4"}
{"t": 1793343328.0221906, "proto": "udp4", "from": "192.168.100.72", "data": "control-udp4"}
{"t": 1793343328.02334, "proto": "tcp6", "from": "fd7a:115c:a1e0::…", "data": "control-tcp6"}
{"t": 1793343328.0233672, "proto": "udp6", "from": "fd7a:115c:a1e0::…", "data": "control-udp6"}
```

**Receipts.** Scope s-6fe3f1b1 (the sender):

```
{"ts":"2026-10-30T06:55:28.463Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command python3; proxy port 50213; 2 protected files"}
{"ts":"2026-10-30T06:55:28.505Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:55:28.568Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=Python pid=9179"}
{"ts":"2026-10-30T06:55:28.568Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47122,"detail":"backend=seatbelt op=network-outbound target=remote:*:47122 process=Python pid=9179"}
{"ts":"2026-10-30T06:55:28.568Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47123,"detail":"backend=seatbelt op=network-outbound target=remote:*:47123 process=Python pid=9179"}
{"ts":"2026-10-30T06:55:28.568Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47124,"detail":"backend=seatbelt op=network-outbound target=remote:*:47124 process=Python pid=9179"}
{"ts":"2026-10-30T06:55:28.582Z","scope":"s-6fe3f1b1","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

Scope s-204d024a (the curls):

```
{"ts":"2026-10-30T06:55:28.585Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command sh; proxy port 50214; 2 protected files"}
{"ts":"2026-10-30T06:55:28.598Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:55:28.611Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=9185"}
{"ts":"2026-10-30T06:55:28.616Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47122,"detail":"backend=seatbelt op=network-outbound target=remote:*:47122 process=curl pid=9186"}
{"ts":"2026-10-30T06:55:28.621Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"proxy","event":"http","verdict":"deny","reason":"port_not_allowed","host":"192.168.100.40","port":47121,"detail":"method=GET"}
{"ts":"2026-10-30T06:55:28.658Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"allowed_by_rule","rule":"example.com","host":"example.com","ip":"2606:4700:10::ac42:93f3","port":443,"detail":"sni_match"}
{"ts":"2026-10-30T06:55:28.714Z","scope":"s-204d024a","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

**Recording.** None yet.

**Limits.**
- macOS writes a kernel log line, and so a `kernel_drop` receipt, only for refusals of
  Apple-signed binaries (here `python3` and `curl`). A refused program that is not signed by Apple
  (a third-party or self-built binary) is blocked the same way but leaves no receipt.
- The kernel prints the remote address as `*`. A `kernel_drop` receipt has the port but not the
  address.
- This run covers TCP connect and UDP send. Raw sockets, ICMP and other protocols were not tested
  here.
- One send of each kind. Under a burst, the kernel log loses some lines. The refusals still happen,
  but some receipts are missing.
- Programs started through launchd, LaunchServices (`open`) or Apple Events run outside the profile.
  The profile refuses those launches, but this run does not test them.
- The IPv6 control path is Tailscale, not the LAN.

**Date.** 30 Oct 2026, 06:55 UTC.
