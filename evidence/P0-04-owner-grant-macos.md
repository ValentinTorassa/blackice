# P0-04: the owner grants from outside; the scope cannot grant itself (macOS)

**Claim.** A command inside a task scope cannot widen its own policy: its `blackice grant` cannot reach the
scope's control socket. The owner's `blackice grant` from outside the scope lets exactly one more name through
the proxy, with an end time. The control socket is gone once the scope ends. Checkpoint P0-04.

**Platform.** macOS 27.0.1 (26A434), arm64 (Apple silicon), SIP enabled.

**Build.** `claude/run` at 58e73cc, `zig build release` with Zig 0.17.0 (cross-compiled on Linux; default
`-Dmacos-min=13.0`). Binary `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`, checked on the Mac before the run.

**Policy.** `policy.json`, id `b0aa1758b9c7`: allow list with only `example.com` (the same file as P0-03).
github.com is not on it.

```json
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com"]
  }
}
```

**Run.** In `/tmp/ns-net` on the Mac, with `XDG_STATE_HOME=/tmp/ns-net/state-p04-1793342475`. One scope runs
the bash script below. It waits on its standard input for the owner's go-ahead, so the steps happen in this
order: check, self-grant, owner grant, check.

```sh
blackice run --policy policy.json -- /bin/bash -c "$INNER" inner /tmp/ns-net/blackice
```

`$INNER`, the scoped command:

```sh
code() { /usr/bin/curl -sS -o /dev/null -m 15 -w "CONNECT %{http_connect}, HTTP %{http_code}" "$1" 2>&1; }
echo "inside: github.com before any grant -> $(code https://github.com)"
sock="$XDG_STATE_HOME/blackice/scopes/$BLACKICE_SCOPE/control.sock"
echo "inside: the control socket is visible:"; ls -l "$sock"
echo "inside: \$ blackice grant $BLACKICE_SCOPE github.com --for 5m"
"$1" grant "$BLACKICE_SCOPE" github.com --for 5m
echo "inside: self-grant exit $?"
echo "inside: github.com after the self-grant -> $(code https://github.com)"
echo "inside: waiting for the owner"
read -r _
echo "inside: github.com after the owner grant -> $(code https://github.com)"
echo "inside: www.github.com (not granted) -> $(code https://www.github.com)"
```

The owner, outside the scope, once the scope prints "waiting for the owner": `blackice grant s-a388327c
github.com --for 2m`, then one line to the scope's standard input. After the scope ended: `ls -l` of the scope
directory, and `blackice grant s-a388327c github.com --for 1m` again.

**Result.**

Scoped command output (stdout and stderr through a pipe):

```
blackice: scope s-a388327c (policy b0aa1758b9c7, macos-seatbelt); receipts: /tmp/ns-net/state-p04-1793342475/blackice/scopes/s-a388327c/receipts.jsonl
blackice: to allow one more host for a while: blackice grant s-a388327c HOST --for 10m
inside: github.com before any grant -> curl: (56) CONNECT tunnel failed, response 403
CONNECT 403, HTTP 000
inside: the control socket is visible:
srw-------  1 valen  wheel  0 Oct 30 03:41 /tmp/ns-net/state-p04-1793342475/blackice/scopes/s-a388327c/control.sock
inside: $ blackice grant s-a388327c github.com --for 5m
blackice: cannot reach the control socket of scope s-a388327c (PermissionDenied). Commands inside a scope cannot reach it; from outside, check that the scope is still running.
inside: self-grant exit 1
inside: github.com after the self-grant -> curl: (56) CONNECT tunnel failed, response 403
CONNECT 403, HTTP 000
inside: waiting for the owner
inside: github.com after the owner grant -> CONNECT 200, HTTP 200
inside: www.github.com (not granted) -> curl: (56) CONNECT tunnel failed, response 403
CONNECT 403, HTTP 000
blackice: scope s-a388327c ended with status 0; 8 receipts
```

Owner, outside the scope:

```
$ blackice grant s-a388327c github.com --for 2m
granted github.com to scope s-a388327c until 2026-10-30T06:43:15.352Z
(exit 0)
```

After the scope ended:

```
$ ls -l /tmp/ns-net/state-p04-1793342475/blackice/scopes/s-a388327c/
total 16
-rw-------  1 valen  wheel   112 Oct 30 03:41 policy.json
-rw-------  1 valen  wheel  1753 Oct 30 03:41 receipts.jsonl
$ blackice grant s-a388327c github.com --for 1m
blackice: cannot reach the control socket of scope s-a388327c (FileNotFound). Commands inside a scope cannot reach it; from outside, check that the scope is still running.
(exit 1)
```

Enforcement points:
- **Self-grant: the Seatbelt profile (OS).** The socket file is visible from inside, mode 0600 and owned by the
  same user, but connecting to it fails with PermissionDenied (EPERM), while the same connect from outside the
  scope works (the owner's grant). The scope's profile denies every outbound network operation except TCP to
  the scope's own localhost ports (`(deny network-outbound)` plus one allow per port), and a connect to a Unix
  socket is refused under that rule (see the follow-up check). **There is no kernel_drop receipt for this
  refusal: macOS wrote no Sandbox log line for it.** macOS does not log Sandbox refusals of binaries that are
  not Apple-signed, and blackice is ad-hoc signed. A python3 connect to the same socket under the same rule was
  logged and receipted. The evidence for the self-grant is therefore the PermissionDenied error, exit 1, the
  absence of any grant receipt from inside, and github.com still answering 403 afterwards.
- **Owner grant: the control socket and the proxy.** The control socket records the owner's grant
  (`owner_grant`, with the caller's pid and the end time). The proxy then lets github.com through with reason
  `granted` and rule `grant:github.com`, and refuses www.github.com (`no_matching_rule`): a grant covers one
  exact name.
- **End of scope.** The control socket is removed with the scope, and a later grant finds nothing to connect
  to.

Follow-up checks on the same Mac and build, each a new scope:

1. 06:51 UTC, scope `s-e57861aa`, running only the self-grant. Then the Sandbox log for that minute:

   ```sh
   blackice run --policy policy.json -- /bin/bash -c '"$1" grant "$BLACKICE_SCOPE" github.com --for 1m; echo self-grant-exit=$?' inner /tmp/ns-net/blackice
   /usr/bin/log show --last 5m --style compact --predicate 'sender == "Sandbox"' | grep -B3 -A1 'blackice s-e57861aa'
   ```

   The self-grant failed the same way (`PermissionDenied`, `self-grant-exit=1`). The only Sandbox lines tagged
   with the scope are blackice's own start and end probes (a sandboxed curl to 127.0.0.1:9; see
   `src/macos/kernel_log.zig`). There is no line for the Unix-socket connect:

   ```
   2026-10-30 03:51:02.307 E  kernel[0:44465] (Sandbox) Sandbox: curl(8879) deny(1) network-outbound remote:*:9
   blackice s-e57861aa
   2026-10-30 03:51:02.330 E  kernel[0:445a8] (Sandbox) Sandbox: curl(8882) deny(1) network-outbound remote:*:9
   blackice s-e57861aa
   ```

2. 06:53 UTC, scope `s-bab51b00`: the Apple-signed python3 from the Command Line Tools connects to the same
   control socket first, then blackice tries its self-grant:

   ```sh
   blackice run --policy policy.json -- /bin/bash -c 'sock=$XDG_STATE_HOME/blackice/scopes/$BLACKICE_SCOPE/control.sock
     /Library/Developer/CommandLineTools/usr/bin/python3 -I -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])" "$sock" 2>&1 | tail -1
     "$1" grant "$BLACKICE_SCOPE" github.com --for 1m; echo self-grant-exit=$?' inner /tmp/ns-net/blackice
   ```

   Both are refused (`PermissionError: [Errno 1] Operation not permitted`, then `PermissionDenied`,
   `self-grant-exit=1`). Only python3's refusal is in the Sandbox log, and only it has a receipt:

   ```
   2026-10-30 03:53:49.675 E  kernel[0:46704] (Sandbox) Sandbox: Python(9084) deny(1) network-outbound /private/tmp/ns-net/state-cause-1793343229/blackice/scopes/s-bab51b00/control.sock
   ```
   ```
   {"ts":"2026-10-30T06:53:49.679Z","scope":"s-bab51b00","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","detail":"backend=seatbelt op=network-outbound target=/private/tmp/ns-net/state-cause-1793343229/blackice/scopes/s-bab51b00/control.sock process=Python pid=9084"}
   ```

   `codesign -dv` shows python3 signed with a team identifier, and blackice `Signature=adhoc` (linker-signed).
   The lead's separate check on this Mac fits the same rule: a C probe built locally with cc and connecting to
   127.0.0.1:9 was not logged, while curl was.

**Receipts.** `s-a388327c`, verbatim:

```
{"ts":"2026-10-30T06:41:15.069Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command bash; proxy port 50161; 3 protected files"}
{"ts":"2026-10-30T06:41:15.083Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:41:15.093Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"github.com","port":443}
{"ts":"2026-10-30T06:41:15.103Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"github.com","port":443}
{"ts":"2026-10-30T06:41:15.352Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"grant","verdict":"allow","reason":"owner_grant","rule":"github.com","host":"github.com","detail":"pid=8260 for 120s until 2026-10-30T06:43:15.352Z"}
{"ts":"2026-10-30T06:41:15.431Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"granted","rule":"grant:github.com","host":"github.com","ip":"4.228.31.150","port":443,"detail":"sni_match grant_until=2026-10-30T06:43:15.352Z"}
{"ts":"2026-10-30T06:41:15.836Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"www.github.com","port":443}
{"ts":"2026-10-30T06:41:15.864Z","scope":"s-a388327c","policy":"b0aa1758b9c7","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

The two denies before the grant are the first check and the check after the self-grant. There is no grant
receipt between them.

**Recording.** None for this run.

**Limits.**
- In v0, any process of the same user outside every scope counts as the owner. The grant came from such a
  process (pid 8260). There is no separate owner credential.
- The self-grant refusal is shown by its error and its effects, not by a kernel receipt. macOS writes no
  Sandbox log line for refusals of binaries that are not Apple-signed, so blackice's own refusals never get
  kernel_drop receipts on macOS. Commands such as curl and python3 do (see the follow-up checks).
- The grant's expiry and the closing of live connections are P0-05, not shown here (the scope ended before the
  2-minute grant did).
- One run, by the person who built it. Not a recording.

**Date.** 2026-10-30, 06:41 UTC.
