# P0-01: the policy is in place before the command runs (macOS)

**Claim.** On macOS, blackice applies the scope's policy before the command's first instruction:
- The command's first network call is refused.
- A grandchild started later is refused the same way, and so is one that outlives the command.
- A command whose policy does not load, or does not match its pinned hash, never starts.

This covers checkpoint P0-01 (policy before execution) for the macOS task scope.

**Platform.** macOS 27.0.1 (26A434), arm64 (MacBook Air), System Integrity Protection enabled.

**Build.** `claude/run` at 58e73cc, built with `zig build release` (Zig 0.17.0, ReleaseSafe, stripped,
macOS minimum 13.0). The binary was `blackice-aarch64-macos`, sha256
`6b6dac302c55c94e875d2803dcd03189ab21d15fa9ff2a8526b99f10f17619f3`. Later commits on the branch were
not part of this run.

**Policy.** `agent.json` (sha256 `b28c9f29dbeafbf9ae0fa9163a3affaefbc997aaedc19c23b3d20bf1dc662760`) is
the same file as in `P0-02-real-deny-macos.md`. It allows `example.com` and `registry.npmjs.org`.
`bad.json` has the single allow entry `"*"`, which v0 refuses.

**Run.** This run is part of `scripts/evidence/p0-01-02-macos.sh`, in the same session as P0-02. The
receiver at 192.168.100.40 was listening and logged the control sends before and after. Commands:

```sh
blackice run --policy agent.json -- /usr/bin/curl --noproxy '*' -sS -m 3 http://192.168.100.40:47121/
blackice run --policy agent.json -- /bin/sh -c "(sleep 1; /usr/bin/curl --noproxy '*' -sS -m 3 http://192.168.100.40:47121/; echo grandchild-curl exit=\$?) & wait"
blackice run --policy agent.json -- /bin/sh -c "(sleep 2; /usr/bin/curl --noproxy '*' -sS -m 3 http://192.168.100.40:47121/ 2>/dev/null; echo \$? > /tmp/ns-e2e/run5-p0102/orphan-exit) >/dev/null 2>&1 & exit 0"
blackice run --policy bad.json -- /bin/sh -c "touch /tmp/ns-e2e/run5-p0102/started"
blackice run --policy agent.json --policy-sha256 0000…0000 -- /bin/sh -c "touch /tmp/ns-e2e/run5-p0102/started2"
```

**Result.** Console output, with `blackice: to allow one more host…` hint lines left out:

```
$ blackice run --policy agent.json -- /usr/bin/curl --noproxy * -sS -m 3 http://192.168.100.40:47121/
blackice: scope s-6fe3102e (policy b28c9f29dbea, macos-seatbelt); receipts: …/s-6fe3102e/receipts.jsonl
curl: (7) Failed to connect to 192.168.100.40 port 47121 after 1 ms: Couldn't connect to server
blackice: scope s-6fe3102e ended with status 7; 4 receipts

$ blackice run -- sh -c "(sleep 1; curl --noproxy * ... ) & wait"   # a grandchild, started later
blackice: scope s-6e4c9a09 (policy b28c9f29dbea, macos-seatbelt); receipts: …/s-6e4c9a09/receipts.jsonl
curl: (7) Failed to connect to 192.168.100.40 port 47121 after 2 ms: Couldn't connect to server
grandchild-curl exit=7

$ blackice run -- sh -c "(sleep 2; curl --noproxy * ...; echo $? > orphan-exit) & exit 0"   # outlives the command
blackice: scope s-4eaa20ff (policy b28c9f29dbea, macos-seatbelt); receipts: …/s-4eaa20ff/receipts.jsonl
blackice: scope s-4eaa20ff ended with status 0; 3 receipts
orphan curl, 2 s after the scope ended: exit 7

$ blackice run --policy bad.json -- sh -c "touch started"   # a policy that does not parse
blackice run: …/bad.json: InvalidPattern: invalid allow entry; use a name or *.name (addresses go in subnets.allow) (*)
exit=125
the command never started: no 'started' file

$ blackice run --policy agent.json --policy-sha256 <wrong hash> -- sh -c "touch started2"
blackice run: …/agent.json does not match --policy-sha256 (it changed after it was pinned); the command was not run
exit=125
the command never started: no 'started2' file
```

- **The first call.** curl's first and only action, a direct connection, was refused at once, in the
  kernel (Seatbelt). The scope's `backend_armed` receipt comes before the refusal.
- **A grandchild started later.** It was started one second after the shell, from a background
  subshell, and was refused the same way, with a `kernel_drop` receipt.
- **A process that outlives the command.** The scope ended at once, and its curl ran two seconds
  later. It was still refused (exit 7). It has no receipt, because blackice stops reading the kernel
  log when the scope ends.
- **A bad policy, or a wrong hash.** blackice stopped before the command both times: no process, no
  marker file, exit 125.
- **The receiver.** It logged nothing from these runs (see P0-02).

**Receipts.**

```
{"ts":"2026-10-30T07:12:42.565Z","scope":"s-6fe3102e","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command curl; proxy port 50517; 2 protected files"}
{"ts":"2026-10-30T07:12:42.592Z","scope":"s-6fe3102e","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"backend_armed","reason":"macos_seatbelt","detail":"profile applied before the command runs; refusal receipts from the kernel log"}
{"ts":"2026-10-30T07:12:42.610Z","scope":"s-6fe3102e","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=10774"}
{"ts":"2026-10-30T07:12:42.626Z","scope":"s-6fe3102e","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":7,"dropped":0}
{"ts":"2026-10-30T07:12:42.630Z","scope":"s-6e4c9a09","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command sh; proxy port 50518; 2 protected files"}
{"ts":"2026-10-30T07:12:43.690Z","scope":"s-6e4c9a09","policy":"b28c9f29dbea","gen":1,"point":"kernel","event":"kernel_drop","verdict":"deny","reason":"loopback_proxy_only","port":47121,"detail":"backend=seatbelt op=network-outbound target=remote:*:47121 process=curl pid=10782"}
{"ts":"2026-10-30T07:12:43.714Z","scope":"s-6e4c9a09","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
{"ts":"2026-10-30T07:12:43.719Z","scope":"s-4eaa20ff","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_start","detail":"backend macos-seatbelt; command sh; proxy port 50519; 2 protected files"}
{"ts":"2026-10-30T07:12:43.761Z","scope":"s-4eaa20ff","policy":"b28c9f29dbea","gen":1,"point":"control","event":"scope_end","status":0,"dropped":0}
```

The two refused starts wrote no scope, so they have no receipts. The evidence for them is the
message, exit status 125, and the missing marker files.

**Recording.** None yet.

**Limits.**
- How it works: blackice starts the command through `/usr/bin/sandbox-exec`, which applies the
  profile and then executes the command. sandbox-exec is deprecated by Apple, but it still works on
  macOS 27.0.1.
- A process started by launchd, LaunchServices or Apple Events would not inherit the profile. The
  profile refuses `launchctl submit` (see P0-02); `open` and Apple Events were not tested here.
- A refusal by a process that outlives the command is enforced (shown above) but gets no receipt.
- blackice writes kernel receipts from the lines macOS logs, and macOS logs refusals of Apple-signed
  binaries only (see P0-02).

**Date.** 30 Oct 2026, 07:12 UTC.
