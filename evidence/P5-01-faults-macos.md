# P5-01: the fault tests on a Mac: 24 checks pass, the last 4 of case 4 fail (macOS)

**Claim.** `macos/scripts/fault-test.sh` ran on a Mac with build 4 and printed 24 PASS and 4 FAIL. The 24 are the 23
numbered checks of cases 1 to 4 that passed, plus the unnumbered check that the daemon registered after
`blackice agent install`. They show that with no daemon a paused connection's event is not sent and the deadline drops
the connection; that a hook hung past the deadline is killed and its connection dropped; that a burst of 120
connections gives one event per app, host and port, at most 64 connections per event and at most 4 hooks at once, with
the rest logged as dropped, while `curl` with a rule still gets HTTP 200; and that launchd starts the daemon again
after it is killed, and it registers within 1 s. The 4 FAILs are the last four checks of case 4, the configuration
change while connections wait. Three failed because the second Touch ID was cancelled, so the change did not happen.
The first failed because `blackice pending` got a reply from the extension that it rejected (see Result). This bears
on phase 5's check, "`macos/scripts/fault-test.sh` passes on a Mac", which this run does not meet.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. Tailscale was
running (see Limits).

**Build.** The build 4 recorded in [P2-02](P2-02-curl-passes-on-retry-nscurl-waits-macos.md), still installed: the
script started 3 minutes after that run and found the configuration it had left (generation 23). Blackice.app 0.1.0,
CFBundleVersion 4, Developer ID signed (team M294LK997M), notarized and stapled.

**Configuration.** Written by the script for the run, `~/Library/Logs/blackice-fault-20261103-115231/fault.toml`:

```toml
# Written by macos/scripts/fault-test.sh for one run.
mode = "ask"
timeout_seconds = 30

# The control for "the Mac keeps working": the system curl may reach pypi.org.
[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

[[hook]]
on = "connection"
run = '/bin/sh ~/Library/Logs/blackice-fault-20261103-115231/hook.sh'
```

The `run` line holds the full path of the home directory; `~` replaces it here. The test hook, also written by the
script, records each event's ID, case, host and its own PID in `hook-calls.log`, never prints the event and answers
nothing. For example.net's first event it sleeps 120 s (case 2), for the burst's distinct hosts 15 s (case 3), and
for anything else it exits at once.

**Run.** A person started the script at the Mac, with its defaults (timeout 30 s, 50 distinct hosts and 70
connections to one host in the burst):
1. It checked the Mac, found the LaunchAgent not loaded, and ran `blackice start` with the test configuration
   (Touch ID 1 of 2; generation 24).
2. Case 1, daemon down: `nscurl https://example.com/` with no daemon, then `blackice pending`.
3. `blackice agent install`.
4. Case 2, hook hung: `nscurl https://example.net/`.
5. Case 3, burst: 50 `nscurl` connections to distinct hosts and 70 to example.org at once, `curl https://pypi.org/`,
   `blackice pending` and `blackice status` during the burst.
6. Case 4, restart: `launchctl kill 9` on the daemon. Then `nscurl` to www.example.com and www.example.net,
   `blackice pending` 4 s later, and `blackice mode accept-all` as the configuration change (Touch ID 2 of 2).
7. The results. On its way out the script switched back to accept-all with one more Touch ID (generation 25) and
   unloaded the LaunchAgent, which it had found unloaded.

**Result.**

| Case | Checks | What happened | Decided by |
|---|---|---|---|
| 1. Daemon down | 5 PASS | example.com's event waited in the pending list with 15 connections; the filter logged `control event_not_sent no_daemon` twice and nothing reached the event log; the deadline dropped the flows (`flow drop timeout`, 30 s in) and `nscurl` failed after 32 s. | extension |
| Daemon back | 1 PASS | After `agent install`, `control xpc daemon_registered`. | launchd, daemon |
| 2. Hook hung | 5 PASS | ev-6a453d69 (example.net) ran the hook, which slept; at the deadline the daemon killed it (`hook_killed`, reason `deadline`, SIGTERM, after 29 223 ms) and its sleep (pid 2101) was gone; the connection timed out 30.8 s after the event and `nscurl` failed after 32 s. | daemon, extension |
| 3. Burst | 10 PASS | The 70 connections to example.org shared one event, which held 64; the filter logged `flow drop ask_capacity` 1026 times (nscurl's retries included). All 50 distinct hosts raised an event. At most 4 hooks ran at once: 4 started and 46 were logged as `hook_dropped` (`concurrency_limit`), and every burst event has one or the other. `curl` reached pypi.org during the burst (HTTP 200, `rule_line_6`), `blackice status` answered and the extension stayed activated and enabled. | extension, daemon |
| 4. Restart | 2 PASS | After `launchctl kill 9`, launchd started the daemon again (pid 2088, then 2630), and it registered within 1 s. | launchd, daemon |
| 4. Configuration change | 1 PASS, 4 FAIL | The new daemon received both events (ev-c091011a, ev-1ca80493) and ran the hook: PASS. The rest failed, as below. | |

The four FAILs:
1. *Both connections were waiting before the change (0 of 2 in the pending list).* `blackice pending`, run 4 s after
   the two connections, printed `the network extension sent an invalid reply: events has an invalid entry` instead of
   a list, so the check found neither host. This one has nothing to do with Touch ID: the two events had reached the
   daemon. From the code, not from this run: an event whose flows were all dropped with `hold_expired` stays pending
   with no connection, `blackice pending` lists it with 0 connections, and the CLI's check of the reply rejects an
   entry with fewer than 1. The run does not show which event it was.
2. *The filter installed the change.* The second Touch ID, for `blackice mode accept-all`, was cancelled, and the CLI
   printed `Touch ID was cancelled or failed; nothing changed`. That was 124 s after the two connections started.
3. *Paused connections were dropped (`flow drop configuration_changed`: 0).* No change, so no such drop.
4. *Their events were cancelled (0 of 2).* Both events had timed out at their 30 s deadline, long before the cancelled
   Touch ID, so they ended `timed_out`.

What checks 2 to 4 measure did happen in the build 4 run just before this one: at the switch to accept-all, the filter
dropped 21 paused flows with `configuration_changed` and the five events still waiting ended `cancelled`
([P2-02](P2-02-curl-passes-on-retry-nscurl-waits-macos.md)).

**Log lines.** The script's result, verbatim:

```
PASS  1. the connection to example.com waited in the pending list
PASS  1. the filter logged 'control event_not_sent no_daemon' (2)
PASS  1. no event reached the event log
PASS  1. the filter logged 'flow drop timeout' at the deadline, 30 s in
PASS  1. nscurl got no response and waited at least the timeout (failed after 32 s)
PASS  the daemon registered with the filter ('control xpc daemon_registered')
PASS  2. the daemon received the event (ev-6a453d69) and the hook took the hung case
PASS  2. the hook was killed at the deadline (hook_killed:deadline after 29223 ms)
PASS  2. the connection was dropped at the deadline (verdict timed_out, 30.8 s after the event)
PASS  2. the hook's sleep is gone (pid 2101)
PASS  2. nscurl got no response (failed after 32 s)
PASS  3. the 70 connections to example.org shared one event (1)
PASS  3. that event held 64 connections, at most 64
PASS  3. connections over 64 per event were dropped ('flow drop ask_capacity': 1026)
PASS  3. 50 of 50 distinct hosts raised an event (50 events)
PASS  3. at most 4 hooks ran at once (most seen in the event log: 4)
PASS  3. hooks over the limit were logged as dropped (4 started, 46 dropped: concurrency_limit)
PASS  3. every burst event ran its hook or was logged as dropped (0 with no record, 0 dropped otherwise, 0 failed)
PASS  3. curl reached pypi.org during the burst (HTTP 200 after 0 s)
PASS  3. blackice status answered during the burst
PASS  3. the extension is still activated and enabled
PASS  4. launchd started the daemon again (pid 2088, then 2630)
PASS  4. the new daemon registered with the filter ('control xpc daemon_registered', seen within 1 s)
PASS  4. the new daemon received both events and ran the hook (2 of 2)
FAIL  4. both connections were waiting before the change (0 of 2 in the pending list; change 124 s in)
FAIL  4. the filter installed the change ('control configuration_installed mode accept-all')
FAIL  4. paused connections were dropped ('flow drop configuration_changed': 0)
FAIL  4. their events were cancelled (0 of 2: www.example.com:timed_out www.example.net:timed_out)
```

Case 4's configuration change, from the run's output:

```
== 4. A configuration change while connections wait: Touch ID (2 of 2)
blackice pending: the network extension sent an invalid reply: events has an invalid entry
Touch ID now: switching back to accept-all is the configuration change this case tests.
blackice: change the mode from ask to accept-all (generation 25)
blackice: Touch ID was cancelled or failed; nothing changed
```

The pending list in case 1:

```
Waiting:
  ev-2f9d419b  apple/com.apple.nscurl -> example.com:443 (2606:4700:10::6814:179a), 15 connections, 26 s left
      /usr/bin/nscurl
```

The filter's log in case 1 (UTC−3; the eight drops at 11:53:05 are shown once):

```
2026-11-03 11:52:35.086 [com.valentorassa.blackice.filter:control] control event_not_sent no_daemon
2026-11-03 11:52:38.044 [com.valentorassa.blackice.filter:control] control event_not_sent no_daemon
2026-11-03 11:53:05.598 [com.valentorassa.blackice.filter:flows] flow drop timeout <private>   (8 lines)
```

The daemon's event log in case 2, with `ip` and `app_path` left out:

```
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T14:53:40Z","event":"ev-6a453d69","host":"example.net","port":443,"ts":"2026-11-03T14:53:10.814Z","type":"event_received"}
{"event":"ev-6a453d69","hook_line":10,"pid":2101,"ts":"2026-11-03T14:53:10.816Z","type":"hook_started"}
{"duration_ms":29223,"event":"ev-6a453d69","hook_line":10,"reason":"deadline","signal":15,"ts":"2026-11-03T14:53:40.038Z","type":"hook_killed"}
{"event":"ev-6a453d69","ts":"2026-11-03T14:53:41.610Z","type":"verdict","verdict":"timed_out"}
```

The burst's pending list (first and example.org's lines) and one dropped hook:

```
  ev-ae671076  apple/com.apple.nscurl -> wikipedia.org:443 (2a02:ec80:700:ed1a::1), 2 connections, 28 s left
  ev-71b4f4a5  apple/com.apple.nscurl -> example.org:443 (2606:4700:10::6814:1a88), 64 connections, 28 s left
{"duration_ms":0,"event":"ev-9f0e0a64","hook_line":10,"reason":"concurrency_limit","ts":"2026-11-03T14:53:43.039Z","type":"hook_dropped"}
```

The restart, from the filter's control log:

```
2026-11-03 11:54:20.524 [com.valentorassa.blackice.filter:control] control xpc daemon_registered 24
```

Case 4's two events, with `ip` and `app_path` left out:

```
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T14:54:51Z","event":"ev-1ca80493","host":"www.example.net","port":443,"ts":"2026-11-03T14:54:21.248Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T14:54:51Z","event":"ev-c091011a","host":"www.example.com","port":443,"ts":"2026-11-03T14:54:21.254Z","type":"event_received"}
{"event":"ev-1ca80493","ts":"2026-11-03T14:54:51.610Z","type":"verdict","verdict":"timed_out"}
{"event":"ev-c091011a","ts":"2026-11-03T14:54:51.611Z","type":"verdict","verdict":"timed_out"}
```

The filter lines above have their process and thread columns cut. The test hook prints nothing, so the run's hook
records carry no token.

**Recording.** None.

**Limits.**
- **Case 4's change is not shown here.** It rests on the build 4 run (P2-02), which measured it outside the script.
- **`blackice pending` failed** in case 4 with an invalid reply. The cause given above is a reading of the code, not
  yet checked by a test or a fix.
- **Counts include retries.** `nscurl` retries while it waits, so the 1026 `ask_capacity` drops count connections,
  not requests.
- **Tailscale.** The script asks for Tailscale's DNS to be off, and the test configuration has no rule for
  Tailscale's extension. Tailscale was running: while the second Touch ID waited, its extension raised events for its
  relay servers, and the filter logged 178 `flow drop no_host` in case 4. No check counts them.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 11:52:31 to about 11:58 UTC−3 (14:52 to 14:58 UTC).
