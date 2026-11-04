# P5-09: the hook queue in the fault tests, with a 0.3.2 candidate

**Claim.** With build 15 (0.3.2), the fault test's burst runs at most 4 hooks at once and the rest wait for a
slot instead of getting no hook: 46 burst hooks waited, some started after waiting, the others were dropped as
`deadline_near`, every burst event ran its hook or was logged as dropped, and the Mac kept working. 22 of the 28
checks passed. The 6 that failed are the connections to `example.com` and `www.example.com` (cases 1 and 4), which
never left `nscurl`: on this network the resolver answered that those names do not exist. Phase 5 (fault tests),
and the "Hooks in a burst" problem in `docs/plan.md`.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Connected
through an iPhone's Personal Hotspot (resolver 172.20.10.1). Tailscale running, its DNS off (`CorpDNS: false`).

**Build.** Blackice.app 0.3.2, build 15, from 672b12d (branch `release-0.3.2`: #30, #31 and the version commit),
built with `macos/scripts/sign.sh` and `package.sh`: Developer ID Application of team M294LK997M, notarized and
stapled. `Blackice-0.3.2.zip` SHA-256 `8576c292d2c73add502a59ed5a1bde45404b7a3e785d8fae07622929b7887331`. Not
published. Installed with the install script from that commit, `BLACKICE_ZIP=… sh site/lib/install.sh --force`
(checksum, signature, team and Gatekeeper checked).

**Configuration.** The one the script writes:

```toml
mode = "ask"
timeout_seconds = 30

[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

[[hook]]
on = "connection"
run = '/bin/sh ~/Library/Logs/blackice-fault-20261104-122419/hook.sh'
```

**Run.** 4 November 2026, on the Mac, from a Claude Code session, with the owner at the keyboard for Touch ID.

1. 12:21: build 15 signed, notarized and packaged (the owner ran the build script, which unlocks the signing
   keychain).
2. 12:23: install over 0.3.1, then `blackice start` with the owner's configuration in accept-all (Touch ID). The
   extension was replaced by 0.3.2/15 and `start` exited with 0: its XPC service answered at once, with no
   restart. The 0.3.1 extension it replaced had been activated over 0.3.0 the same morning and had never been
   reachable (no restart in between). Then `blackice agent uninstall` and `agent install`, so that the daemon
   runs the new binary.
3. 12:24: `macos/scripts/fault-test.sh` (defaults: 30 s timeout, 50 distinct hosts, 70 connections to one host).
   Touch ID at the start and for the switch back to accept-all at the end.

**Result.**

```text
FAIL  1. the connection to example.com waited in the pending list
PASS  1. the filter logged 'control event_not_sent no_daemon' (4)
PASS  1. no event reached the event log
FAIL  1. the filter logged 'flow drop timeout' at the deadline, 30 s in
FAIL  1. nscurl got no response and waited at least the timeout (failed after 5 s)
PASS  the daemon registered with the filter ('control xpc daemon_registered')
PASS  2. the daemon received the event (ev-9ba8ed35) and the hook took the hung case
PASS  2. the hook was killed at the deadline (hook_killed:deadline after 29879 ms)
PASS  2. the connection was dropped at the deadline (verdict timed_out, 30.6 s after the event)
PASS  2. the hook's sleep is gone (pid 2706)
PASS  2. nscurl got no response (failed after 32 s)
PASS  3. the 70 connections to example.org shared one event (1)
PASS  3. that event held 64 connections, at most 64
PASS  3. connections over 64 per event were dropped ('flow drop ask_capacity': 209)
PASS  3. 50 of 50 distinct hosts raised an event (50 events)
PASS  3. at most 4 hooks ran at once (most seen in the event log: 4)
PASS  3. hooks over the limit waited for a slot (46 queued, 4 of 8 started after waiting)
PASS  3. every burst event ran its hook or was logged as dropped (0 with no record, 42 dropped while waiting, 0 dropped otherwise, 0 failed)
PASS  3. curl reached pypi.org during the burst (HTTP 200 after 1 s)
PASS  3. blackice status answered during the burst
PASS  3. the extension is still activated and enabled
PASS  4. launchd started the daemon again (pid 2692, then 3605)
PASS  4. the new daemon registered with the filter ('control xpc daemon_registered', seen within 0 s)
FAIL  4. the new daemon received both events and ran the hook (1 of 2)
FAIL  4. both connections were waiting before the change (1 of 2 in the pending list; change 7 s in)
PASS  4. the filter installed the change ('control configuration_installed mode accept-all')
PASS  4. paused connections were dropped ('flow drop configuration_changed': 218)
FAIL  4. their events were cancelled (1 of 2: www.example.com:- www.example.net:cancelled)
```

The queue was decided by the daemon. In the burst the test hook takes about 15 s, so with 4 slots and 30 s per event
the first wave ran, the next started after waiting about 15 s, and the rest were given up when less than 10 s was
left. Over the whole case 3 window, which also held the Mac's own apps that had no rule in the test configuration,
the daemon logged 91 `hook_queued`, 48 hooks started after waiting (9 ms to 15.7 s), and 43 `hook_dropped`, all
`deadline_near`, with at most 80 waiting at once.

The failures: both `nscurl` runs to `example.com` (case 1) and `www.example.com` (case 4) ended within 5 s with
NSURLErrorDomain -1003, "A server with the specified hostname could not be found", before any connection, so
nothing reached the filter. After a restart the system resolver still answered `No Such Record` for
`example.com` (`dns-sd -G v4v6`), and the hotspot's resolver answered NXDOMAIN for `example.com`,
`www.example.com` and, by then, `example.net` (`dig @172.20.10.1`), while `dig` through it had returned addresses
for `example.com` earlier the same hour. The other half of case 4, `www.example.net`, waited, ran its hook and was
cancelled by the configuration change, as the check expects.

**Log lines.** From the daemon's event log (`3-events.jsonl` in the run's work folder), `stderr` left out:

```json
{"ts":"2026-11-04T15:25:05.515Z","type":"hook_started","event":"ev-7e05477a","hook_line":10,"pid":2983}
{"ts":"2026-11-04T15:25:21.016Z","type":"hook_started","event":"ev-9311b68c","hook_line":10,"waited_ms":15018,"pid":3179}
{"ts":"2026-11-04T15:25:26.894Z","type":"hook_dropped","event":"ev-42413a12","hook_line":10,"waited_ms":19999,"reason":"deadline_near","duration_ms":0}
```

From `nscurl` (case 1):

```text
Load failed with error: Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not be found." … _NSURLErrorNWResolutionReportKey=Resolved 0 endpoints in 138ms using unknown from cache …
```

**Recording.** None. The run's output and work files are in `~/Library/Logs/blackice-fault-20261104-122419/` on
the Mac.

**Limits.** Cases 1 and 4 did not test what they are for, because their host names did not resolve on this
network: they need a run on another network. One run, one Mac, with the test hook rather than an agent; the 10 s
start budget and the 256 cap are first guesses, and the cap was not reached. The upgrade without a restart is one
case, after an upgrade whose extension had never been reachable, and does not show that upgrades no longer need
one.

**Date.** 4 November 2026.
