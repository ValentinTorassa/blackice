# P0-01: the policy is in place before the command runs (macOS)

**Claim.** On macOS, blackice applies the scope's policy before the command's first instruction.
The command's first network call is refused, a grandchild started later is refused the same way,
and a command whose policy does not load, or does not match its pinned hash, never starts.
Checkpoint P0-01 (policy before execution), macOS task scope.

**Platform.** macOS 27.0.1 (26A434), arm64 (MacBook Air), System Integrity Protection enabled.

**Build.** `claude/run` at 58e73cc, built with `zig build release` (Zig 0.17.0, ReleaseSafe,
stripped, macOS minimum 13.0). The binary was `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`.

**Policy.** `agent.json` (sha256 `b28c9f29dbeafbf9ae0fa9163a3affaefbc997aaedc19c23b3d20bf1dc662760`),
the same file as in `P0-02-real-deny-macos.md`. It allows `example.com` and `registry.npmjs.org`.
`bad.json` has the single allow entry `"*"`, which v0 refuses.

**Run.** This is the second half of `scripts/evidence/p0-01-02-macos.sh`, run in the same session
as P0-02. The receiver at 192.168.100.40 was listening.

```sh
blackice run --policy agent.json -- /usr/bin/curl --noproxy '*' -sS -m 3 http://192.168.100.40:47121/
blackice run --policy agent.json -- /bin/sh -c "(sleep 1; /usr/bin/curl --noproxy '*' -sS -m 3 http://192.168.100.40:47121/; echo grandchild-curl exit=\$?) & wait"
blackice run --policy bad.json -- /bin/sh -c "touch /tmp/ns-e2e/evidence-run/started"
blackice run --policy agent.json --policy-sha256 0000…0000 -- /bin/sh -c "touch /tmp/ns-e2e/evidence-run/started2"
```

**Result.**
- curl's first and only action, a direct connection, was refused at once (exit 7, "Couldn't
  connect to server" after 0 ms). The enforcement point was the kernel (Seatbelt). The scope's
  `backend_armed` receipt comes before the refusal.
- A grandchild started one second after the shell, from a background subshell, was refused the
  same way (exit 7), with a `kernel_drop` receipt.
- With `bad.json`, blackice stopped before the command: `blackice run: …/bad.json: InvalidPattern:
  invalid allow entry; use a name or *.name (addresses go in subnets.allow) (*)`, exit 125. The
  command never ran, and no `started` file exists.
- With a hash that does not match the policy file: `blackice run: …/agent.json does not match
  --policy-sha256 (it changed after it was pinned); the command was not run`, exit 125. No
  `started2` file exists.
- The receiver logged nothing from these runs (see P0-02).

**Receipts.**

```
{"ts":"2026-10-30T06:55:28.717Z","scope":"s-fcc4660e","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50218; 2 protected files"}
{"ts":"2026-10-30T06:55:28.732Z","scope":"s-fcc4660e","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:55:28.743Z","scope":"s-fcc4660e","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=9193"}
{"ts":"2026-10-30T06:55:28.756Z","scope":"s-fcc4660e","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":7,"dropped":0}
{"ts":"2026-10-30T06:55:28.758Z","scope":"s-7228523a","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command sh; proxy port 50219; 2 protected files"}
{"ts":"2026-10-30T06:55:28.771Z","scope":"s-7228523a","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T06:55:29.815Z","scope":"s-7228523a","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=9201"}
{"ts":"2026-10-30T06:55:29.842Z","scope":"s-7228523a","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

The two refused starts wrote no scope, so they have no receipts. The evidence for them is the
message, exit status 125, and the missing marker files.

**Recording.** None yet.

**Limits.**
- How it works: blackice starts the command through `/usr/bin/sandbox-exec`, which applies the
  profile and then executes the command. sandbox-exec is deprecated by Apple, but it still works on
  macOS 27.0.1.
- A process started through launchd, LaunchServices or Apple Events would not inherit the profile.
  The profile refuses those launches, but this run does not exercise them.
- Refusals by a process that outlives the command are enforced but are not read into receipts after
  the scope ends.
- macOS writes receipts only for refusals of Apple-signed binaries (see P0-02).

**Date.** 30 Oct 2026, 06:55 UTC.
