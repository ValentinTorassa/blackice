# P0-03: a small explicit allow on macOS

**Claim.** With a policy that allows only `example.com`, a command in a task scope reaches example.com over
HTTPS and plain HTTP. github.com is refused on both, and the proxy writes an allow or a deny receipt for each
connection. Checkpoint P0-03.

**Platform.** macOS 27.0.1 (26A434), arm64 (Apple silicon), SIP enabled.

**Build.** `claude/run` at 58e73cc, `zig build release` with Zig 0.17.0 (cross-compiled on Linux; default
`-Dmacos-min=13.0`). Binary `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`, checked on the Mac before the run.

**Policy.** `policy.json`, id `b0aa1758b9c7`:

```json
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com"]
  }
}
```

`blackice policy check`: `mode allowlist, 1 allowed names, 0 allowed subnets, 0 denied subnets, ports 80 443`.

**Run.** In `/tmp/ns-net` on the Mac, with `XDG_STATE_HOME=/tmp/ns-net/state-p03-1793342392`. Each command
runs in its own scope:

```sh
blackice run --policy policy.json -- /usr/bin/curl -sS -m 20 -o /dev/null -w 'HTTP %{http_code}\n' https://example.com
blackice run --policy policy.json -- /usr/bin/curl -sS -m 20 -o /dev/null -w 'CONNECT %{http_connect}, HTTP %{http_code}\n' https://github.com
blackice run --policy policy.json -- /usr/bin/curl -sS -m 20 -o /dev/null -w 'HTTP %{http_code}\n' http://example.com/
blackice run --policy policy.json -- /usr/bin/curl -sS -m 20 -o /dev/null -w 'HTTP %{http_code}\n' http://github.com/
```

**Result.** Enforcement point: the scope's proxy. curl uses it through `HTTPS_PROXY` / `HTTP_PROXY`, which
blackice sets. The Seatbelt profile leaves no direct way out (that is P0-01 and P0-02).

| Command | Output | Exit |
|---|---|---|
| `https://example.com` | `HTTP 200` | 0 |
| `https://github.com` | `curl: (56) CONNECT tunnel failed, response 403` / `CONNECT 403, HTTP 000` | 56 |
| `http://example.com/` | `HTTP 200` | 0 |
| `http://github.com/` | `HTTP 403` | 0 |

For HTTPS the proxy answers the CONNECT. For the allowed name it resolves example.com itself and checks that
the TLS SNI equals the name (`sni_match`). For plain HTTP it decides on the request's host.

**Receipts.** One file per scope, verbatim:

```
{"ts":"2026-10-30T06:39:52.691Z","scope":"s-214fc7b0","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50137; 3 protected files"}
{"ts":"2026-10-30T06:39:52.705Z","scope":"s-214fc7b0","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:39:52.745Z","scope":"s-214fc7b0","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"allowed_by_rule","rule":"example.com","host":"example.com","ip":"2606:4700:10::ac42:93f3","port":443,"detail":"sni_match"}
{"ts":"2026-10-30T06:39:52.803Z","scope":"s-214fc7b0","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

```
{"ts":"2026-10-30T06:39:52.807Z","scope":"s-daca353c","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50140; 3 protected files"}
{"ts":"2026-10-30T06:39:52.821Z","scope":"s-daca353c","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:39:52.831Z","scope":"s-daca353c","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"github.com","port":443}
{"ts":"2026-10-30T06:39:52.843Z","scope":"s-daca353c","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":56,"dropped":0}
```

```
{"ts":"2026-10-30T06:39:52.845Z","scope":"s-2124f2a4","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50142; 3 protected files"}
{"ts":"2026-10-30T06:39:52.859Z","scope":"s-2124f2a4","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:39:52.886Z","scope":"s-2124f2a4","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"http","verdict":"allow","reason":"allowed_by_rule","rule":"example.com","host":"example.com","ip":"2606:4700:10::ac42:93f3","port":80,"detail":"method=GET"}
{"ts":"2026-10-30T06:39:52.919Z","scope":"s-2124f2a4","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

```
{"ts":"2026-10-30T06:39:52.922Z","scope":"s-5a2db432","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50145; 3 protected files"}
{"ts":"2026-10-30T06:39:52.935Z","scope":"s-5a2db432","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:39:52.944Z","scope":"s-5a2db432","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"http","verdict":"deny","reason":"no_matching_rule","host":"github.com","port":80,"detail":"method=GET"}
{"ts":"2026-10-30T06:39:52.957Z","scope":"s-5a2db432","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

**Recording.** None for this run.

**Limits.**
- The allow and deny decisions here are the proxy's, for a client that uses the proxy. A command that ignores
  the proxy variables is the Seatbelt profile's job, shown in P0-01 and P0-02, not here.
- One exact name only. Subdomains, wildcard rules, subnets and ports other than 80 and 443 were not exercised.
- The proxy decides on the destination name and port. Content inside an allowed TLS connection is not inspected.
- One run, by the person who built it. Not a recording.

**Date.** 2026-10-30, 06:39 UTC.
