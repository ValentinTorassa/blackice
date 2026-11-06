# P5-11: the fault tests pass with the published 0.4.5

**Claim.** With the published 0.4.5, `macos/scripts/fault-test.sh` passed all 29 checks on a Mac: daemon down, hook
hung, the burst (at most 4 hooks, the rest waiting for a slot), the daemon's restart, and a configuration change to
accept-all that lets the paused connections go and cancels their events. It is the first run where the two
`example.com` cases resolved (P5-09 failed them), and the first of the accept-all change on a Mac. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, resolver
8.8.8.8 for the run: Tailscale running with its DNS off (`tailscale set --accept-dns=false`), on again after.

**Build.** Blackice.app 0.4.5, build 26, as published (Developer ID Application of team M294LK997M).
`fault-test.sh` from branch `e2e-0.4.5` at 40480b1, which reads `blackice pending` as 0.4.5 prints it and keeps
its own `log stream` copy of the filter's lines.

**Configuration.** The one the script writes:

```toml
mode = "ask"
timeout_seconds = 30

[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

[[hook]]
on = "connection"
program = "/bin/sh"
app = "com.apple.sh"
args = ["/Users/valen/Library/Logs/blackice-fault-20261106-111707/hook.sh"]
```

**Run.** 6 November 2026, 14:17 to 14:19 UTC, from a Claude Code session on the Mac, with the owner at the keyboard
for the two Touch ID prompts. Defaults: 30 s timeout, 50 distinct hosts and 70 connections to one host.

A first run at 13:06 UTC, with the script as it was on main, stopped after case 1. Its check of `blackice pending`
looked for the pre-0.4.5 form (`apple/com.apple.nscurl -> example.com:443 (…), N connections`), though the
connection was listed as waiting (`com.apple.nscurl → example.com:443  2 connections, 26s left`). And its reads of
the filter's lines with `log show` found none of the `control` lines: on that Mac, with the data volume 99% full,
`log stream` saw 107 lines of the filter's subsystem in 10 s and `log show` kept none of them. The script now reads
both as they are, and the run below is with that script.

**Result.**

```text
PASS  1. the connection to example.com waited in the pending list
PASS  1. the filter logged 'control event_not_sent no_daemon' (5)
PASS  1. no event reached the event log
PASS  1. the filter logged 'flow drop timeout' at the deadline, 30 s in
PASS  1. nscurl got no response and waited at least the timeout (failed after 31 s)
PASS  the daemon registered with the filter ('control xpc daemon_registered')
PASS  2. the daemon received the event (ev-d7233427) and the hook took the hung case
PASS  2. the hook was killed at the deadline (hook_killed:deadline after 29698 ms)
PASS  2. the connection was dropped at the deadline (verdict timed_out, 30.6 s after the event)
PASS  2. the hook's sleep is gone (pid 34859)
PASS  2. nscurl got no response (failed after 31 s)
PASS  3. the 70 connections to example.org shared one event (1)
PASS  3. that event held 64 connections, at most 64
PASS  3. connections over 64 per event were dropped ('flow drop ask_capacity': 76)
PASS  3. 50 of 50 distinct hosts raised an event (50 events)
PASS  3. at most 4 hooks ran at once (most seen in the event log: 4)
PASS  3. hooks over the limit waited for a slot (46 queued, 4 of 8 started after waiting)
PASS  3. every burst event ran its hook or was logged as dropped (0 with no record, 42 dropped while waiting, 0 dropped otherwise, 0 failed)
PASS  3. curl reached pypi.org during the burst (HTTP 200 after 14 s)
PASS  3. blackice status answered during the burst
PASS  3. the daemon started /bin/sh after checking its signature, and refused none (0 hook_refused)
PASS  3. the extension is still activated and enabled
PASS  4. launchd started the daemon again (pid 34849, then 35389)
PASS  4. the new daemon registered with the filter ('control xpc daemon_registered', seen within 1 s)
PASS  4. the new daemon received both events and ran the hook (2 of 2)
PASS  4. both connections were waiting before the change (2 of 2 in the pending list; change 12 s in)
PASS  4. the filter installed the change ('control configuration_installed mode accept-all')
PASS  4. accept-all let the paused connections go ('flow allow accept_all;configuration_changed': 49)
PASS  4. their events were cancelled (2 of 2: www.example.com:cancelled www.example.net:cancelled)
```

Decided by: the extension (timeouts, the 64-per-event limit, the change to accept-all), the daemon (the hook
queue, the deadline kill, the signature check of `/bin/sh`) and launchd (the restart).

**Log lines.** From the run's `stream.log` (local time, UTC−3):

```text
2026-11-06 11:17:17.145 Df com.valentorassa.blackice.filter[74003:417a17] [com.valentorassa.blackice.filter:control] control event_not_sent no_daemon
2026-11-06 11:17:48.018 Df com.valentorassa.blackice.filter[74003:416f89] [com.valentorassa.blackice.filter:flows] flow drop timeout app=apple/com.apple.nscurl <private>
2026-11-06 11:17:51.145 Df com.valentorassa.blackice.filter[74003:417c9f] [com.valentorassa.blackice.filter:control] control xpc daemon_registered 49
2026-11-06 11:18:23.518 Df com.valentorassa.blackice.filter[74003:417fbc] [com.valentorassa.blackice.filter:flows] flow drop ask_capacity app=apple/com.apple.nscurl <private>
2026-11-06 11:19:12.475 Df com.valentorassa.blackice.filter[74003:418c94] [com.valentorassa.blackice.filter:control] control configuration_installed mode accept-all, 1 allow rule, 1 hook, generation 5
2026-11-06 11:19:12.472 Df com.valentorassa.blackice.filter[74003:418c94] [com.valentorassa.blackice.filter:flows] flow allow accept_all;configuration_changed app=EQHXZ8M8AV/com.google.Chrome.helper <private>
```

**Limits.**

- After the run, `blackice start` with the owner's file kept accept-all ("Keeping accept-all mode from blackice mode
  or the menu; the file says ask"): the script's switch to accept-all, made while the test file was loaded, counted
  as the owner's own switch. `blackice mode ask --agent claude-code` put it back. Not fixed yet.
- `blackice report` reads the same unified log with `log show`, so on a Mac that keeps few of the filter's lines it
  reports few connections. Not fixed here.
- Not covered: an upgrade in place, a first install, and macOS 14 and 15.

**Date.** 6 November 2026.
