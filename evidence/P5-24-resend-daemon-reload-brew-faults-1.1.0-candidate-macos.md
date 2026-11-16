# P5-24: the 1.1.0 candidate sends waiting events to a daemon that registers and loads the daemon again after an upgrade

**Claim.** On build 65, the 1.1.0 candidate, and on builds 63 and 64 before it, a daemon that registered got the
events still waiting for an answer: after a SIGKILL of a frozen daemon, after a SIGTERM while a hook ran, and after
an upgrade's `start`, where three events raised in the 10 s with no daemon were sent again and fx answered them in
3.2 to 4.4 s. On 1.0.7 and 1.0.8 the same day such events were never sent. After Homebrew removed the daemon's
LaunchAgent, build 65's `start` loaded it again and said so; 1.0.8's `start` after a `brew upgrade` left no daemon
and said `fx answers`. A first install of 1.0.8 from the site set up ask mode with fx in one `start`. In 16 hours
of the owner's use on builds 63 and 64, fx answered 233 of 246 events, and the Mac slept through the hooks of the
other 13. Of the fault test's 29 checks on build 65, the 28 that the run's work files and logs can show again
pass; they do not keep what the 29th needs. Phases 4 and 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), kernel xnu-13432.1.9~1, arm64, System Integrity
Protection on, FileVault on. Wi-Fi. For steps 8 and 9 Tailscale's DNS was off. The network's router
(192.168.1.1) does not resolve example.com or www.example.com, so for the fault tests the Wi-Fi service's DNS
server was 1.1.1.1.

**Builds.** Each signed with the Developer ID Application of team M294LK997M and notarized; the app's and the
extension's Info.plist name the commit (`BlackiceSourceCommit`):

- 1.0.7 (build 58) and 1.0.8 (build 62), as published: the Homebrew cask and the site's install script;
- build 63, Blackice.app 1.0.8 from 75c62b0: 1.0.8 with the events sent again to a daemon that registers.
  `Blackice-1.0.8.zip` SHA-256 `875f0422…3017`;
- build 64, Blackice.app 1.1.0 from 491b61f: also runs an event's hooks once when it reaches the daemon twice.
  `Blackice-1.1.0.zip` SHA-256 `194e7d8f…3138`;
- build 65, Blackice.app 1.1.0 from 17f4e4c, the candidate: also loads the daemon again when `start` finishes an
  upgrade. `spctl` accepted it as `source=Notarized Developer ID`. `Blackice-1.1.0.zip` SHA-256
  `f26bb83c1ac96aca0a6acfc026cbb099d390fa2de08c82b5395dc056538380f0`.

Before signing, build 65's tree passed the steps of `.github/workflows/ci.yml` on this Mac: `swift build
-Xswiftc -warnings-as-errors`, `macos/test.sh` (654 tests in 76 suites), `macos/smoke.sh`, and `sign.sh`,
`package.sh` and `fault-test.sh` with `DRY=1`.

**Configuration.** The owner's file: ask mode, fx answering (Claude Code and Codex also connected), 60 s to answer,
25 rules, 1 hook. For the first install, the file `start` wrote: ask mode, fx, 35 rules. For the fault tests the
script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**Run.** 15 and 16 November 2026 (UTC−3). The owner ran every install, upgrade, `stop` and `start` in his own
terminal, from a script that runs each command and keeps its output, and answered every Touch ID, Homebrew's
password prompt and macOS's dialogs. A Claude Code session on the Mac sent the signals of step 8 and read the logs.
A replacement with a build that is not published is the install script with `BLACKICE_ZIP` and `--force`.

1. Build 63 in the owner's use, from 22:18 on 15 November to 10:00 on 16 November.
2. 10:00: `blackice stop` on 63 and the app moved to the Trash; `brew install --cask` of the tap's 1.0.7 cask;
   `blackice start`.
3. 10:01: `brew upgrade --cask` to 1.0.8, `blackice status`, `blackice start`, `blackice status`.
4. 10:02: `blackice stop`, `brew uninstall --cask`, and the owner's file moved aside; 1.0.8 from the site's
   install script; a first `blackice start`, picking ask mode and fx.
5. 10:04: the owner's file back, 1.0.8 replaced with build 64, `blackice start`. Build 64 in the owner's use
   until 14:19.
6. 14:19: `blackice stop` on 64 and the app moved to the Trash; `brew install --cask` of the 1.0.8 cask;
   `blackice start`.
7. 14:19:43: `brew uninstall --cask`, which runs the cask's `uninstall launchctl:` as `brew upgrade` does; build
   65 from the install script; `blackice start`; `curl https://www.ietf.org/`.
8. 14:23, on 65: the daemon frozen with SIGSTOP, `curl https://datatracker.ietf.org/` opened, the daemon killed
   with SIGKILL 5 s later. Then `curl https://www.unicode.org/` opened and a SIGTERM to the daemon 1.5 s later.
   curl had no rule or approval for either host.
9. 14:32, on 65: `macos/scripts/fault-test.sh`, with 1.1.1.1 as the Wi-Fi service's DNS server for the run.

**Result.**

1. A daemon that registers gets the events still waiting, and their hooks answer them. On build 65:

   ```text
   14:23:16  SIGSTOP to the daemon (pid 22637); curl to datatracker.ietf.org opened
   14:23:21  SIGKILL
   2026-11-16 14:23:21.942 control xpc daemon_registered 2
   2026-11-16 14:23:21.942 control events_sent_again 1 of 1
   {"event":"ev-affd5bea","host":"datatracker.ietf.org","ts":"2026-11-16T17:23:21.973Z","type":"event_received"}
   {"duration_ms":3245,"event":"ev-affd5bea","hook_line":141,"status":0,"ts":"2026-11-16T17:23:25.218Z","type":"hook_exited"}
   {"event":"ev-affd5bea","ts":"2026-11-16T17:23:25.220Z","type":"verdict","verdict":"approved"}
   ```

   The frozen daemon never logged the event; the daemon launchd started next (pid 24664) received it as it
   registered, fx approved it in 3.2 s and curl got HTTP 200 in 8.5 s. With the SIGTERM, the first daemon stopped
   the hook and the next one (pid 24778) ran it again for the same event:

   ```text
   {"event":"ev-72c13d52","host":"www.unicode.org","ts":"2026-11-16T17:23:36.053Z","type":"event_received"}
   {"duration_ms":1499,"event":"ev-72c13d52","hook_line":141,"reason":"daemon_stopping","signal":15,"ts":"2026-11-16T17:23:37.552Z","type":"hook_killed"}
   2026-11-16 14:23:37.591 control xpc daemon_registered 2
   2026-11-16 14:23:37.592 control events_sent_again 1 of 1
   {"event":"ev-72c13d52","host":"www.unicode.org","ts":"2026-11-16T17:23:37.624Z","type":"event_received"}
   {"duration_ms":3110,"event":"ev-72c13d52","hook_line":141,"status":0,"ts":"2026-11-16T17:23:40.734Z","type":"hook_exited"}
   {"event":"ev-72c13d52","ts":"2026-11-16T17:23:40.738Z","type":"verdict","verdict":"approved"}
   ```

   curl got HTTP 200 in 5.2 s. On build 62 the day before, the same SIGTERM left the connection waiting for its
   deadline and curl failed after 60.2 s (P5-23). (The `event_received` lines are cut to the fields shown.)
2. An upgrade's `start` no longer loses the events raised before the daemon is back. Each `start` below turned the
   filter on with no daemon registered yet, and three connections came in that time:

   | `start` of | Filter started | `event_not_sent no_daemon` | Daemon registered | Sent again |
   |---|---|---|---|---|
   | 1.0.7 (build 58), after `brew install` | 10:01:10.796 | 10:01:15.6, 10:01:16.8, 10:01:17.0 | 10:01:17.437 | no |
   | 1.0.8 (build 62), after `brew upgrade` | 10:02:40.565 | 10:02:40.8, 10:02:42.3, 10:02:46.4 | never | no |
   | build 64, replacing 1.0.8 | 10:04:11.731 | 10:04:12.5, 10:04:14.9, 10:04:19.7 | 10:04:21.239 | `events_sent_again 3 of 3` at 10:04:21.240 |

   On build 64 the daemon received the three at 13:04:21.265Z (`ev-26678d04`, `ev-55b563c3`, `ev-a02bf045`) and fx
   denied them after 3.2, 3.6 and 4.4 s. On 1.0.7 and 1.0.8 no event of those six reached the event log.
3. `brew upgrade` removes the daemon, and 1.0.8's `start` left it so. Homebrew printed `Removing launchctl
   service` for the daemon's label and asked for the password; after it `blackice status` said:

   ```text
     daemon     not running, so no hook runs: blackice agent install
     filter     still build 58, and this app is build 62: blackice start finishes the upgrade
   ```

   `blackice start` then printed `✓ blackice is on in ask mode, fx answers` and `✓ The menu bar app runs this build
   now`, and nothing about the daemon. `status` still said `daemon not running`, and the three connections of the
   table's second row waited with nobody to answer.
4. Build 65's `start` loads the daemon again. After `brew uninstall --cask` launchd no longer had the daemon and
   its LaunchAgent file was gone, with 1.0.8's filter still on (one more `event_not_sent no_daemon`, at
   14:19:50.847). With build 65 in place, `start` printed:

   ```text
   Touch ID to start filtering in ask mode, 25 rules, 1 hook, 60 s to answer…
   ✓ blackice is on in ask mode, fx answers
   ✓ The daemon runs your hooks, now and at each login (logs in ~/Library/Logs/blackice)
   ```

   The filter started at 14:19:57.717 and the daemon registered 0.65 s later, at 14:19:58.367 (`configuration
   generation 2, 1 hook, timeout 60 s`). The LaunchAgent file was back, and `status` had no `daemon` line. curl's
   connection to www.ietf.org waited, fx approved it and curl got HTTP 200 in 3.8 s.
5. A first install of 1.0.8 from the site, with no file of the owner's: the install script printed `✓ Checked the
   checksum, the signature (team M294LK997M), the notarization and the version: 1.0.8, build 62`. `start` saved
   `ask mode, 34 rules`, asked for Touch ID and for the extension to be allowed, went `on in accept-all mode until
   fx is set up`, connected fx (`✓ approved it in 3 s`), and ended with `Touch ID to start filtering in ask mode,
   35 rules, 1 hook, 60 s to answer…`, `✓ blackice is on in ask mode, fx answers` and `✓ The daemon runs your
   hooks, now and at each login`. The filter installed ask mode at 10:03:49.198 and the daemon registered 0.6 s
   later.
6. Going back to an older build needed no restart of the Mac: after `blackice stop` on build 63 and on build 64,
   the `start` of 1.0.7 and of 1.0.8 asked for the extension to be allowed again and macOS activated it
   (`com.valentorassa.blackice.filter (1.0.7/58) … [activated enabled]`).
7. In the owner's use, fx answered every event raised while the Mac was awake:

   | Build | From, to | Events | Answered | Timed out | Answered hooks: median, 90th percentile, longest |
   |---|---|---|---|---|---|
   | 63 | 15 Nov 22:18, 16 Nov 10:00 | 132 | 120 (85 approved, 35 denied) | 12 | 3.9 s, 5.6 s, 6.6 s |
   | 64 | 16 Nov 10:04, 14:19 | 114 | 113 (54 approved, 59 denied) | 1 | 3.8 s, 5.5 s, 7.5 s |

   The 13 that timed out were Discord's helper's, and the `hook_killed` line of each has `slept_ms` (913,703 for
   the one at 03:25:39Z): the Mac slept past the deadline. The event log has no `hooks_skipped` line on builds 63
   to 65: no event reached the same daemon twice.
8. The fault tests on build 65 (work files `blackice-fault-20261116-143210`). The script prints its checks and keeps
   no copy of them. Afterwards 20 were computed again from the work files with the script's own functions, and 8
   more read from the work files, the daemon's log and the process list; the 28 pass:
   - no daemon: the connection to example.com waited in the pending list (`2 connections, 26s left`), the filter
     logged `event_not_sent no_daemon` 3 times, no event reached the event log, and the filter dropped it at
     14:32:48.750, 30.7 s after it asked (`flow drop timeout`); nscurl ended with `Load failed`;
   - `blackice agent install`: the daemon registered at 14:32:51.693, with `events_sent_again 2 of 2` for two other
     apps' connections that were waiting;
   - hung hook: killed at the deadline after 29,305 ms (`hook_killed`, `deadline`), verdict `timed_out`, and its
     process is gone;
   - burst: the 70 connections to example.org shared one event that held 64, with `flow drop ask_capacity` for the
     rest; 50 of 50 hosts raised an event; at most 4 hooks ran at once, 46 were queued, 8 started (4 after waiting)
     and 42 were dropped while waiting, none unrecorded, failed or refused; `blackice status` answered (`blackice
     is on in ask mode`);
   - restart: the daemon (pid 28865) was killed with SIGKILL and launchd's next one (pid 29980) registered at
     14:34:00.575; both test connections waited in the pending list and their hooks ran; `configuration_installed
     mode accept-all` at 14:34:08.810 let them go (`flow allow accept_all;configuration_changed`, 23 lines) and
     both events were cancelled.

   The 29th check is curl's HTTP status for pypi.org during the burst, which the work files do not keep: the filter
   allowed curl's flow by its rule and curl wrote no error.
9. A new daemon runs the hook again for an event its predecessor already ran it for. At that restart the filter
   logged `events_sent_again 4 of 4`: four events of other apps' connections, received between 17:33:48Z and
   17:33:58Z by the daemon that was killed, whose test hook had exited with no answer, were received again at
   17:34:00.580Z and the hook ran a second time for each.

**Limits.** One Mac, macOS 27.0.1. `brew upgrade` to 1.1.0 itself was not run, which needs the published zip and
cask: step 7 has Homebrew's own removal of the daemon, then the candidate from the install script. The fault test's
printed list of checks was not kept, and its run had 1.1.1.1 as the DNS server, not the network's router. An event
that reaches the same daemon twice (`hooks_skipped`, `already_received`) happened in no run; only a unit test has
it. Result 9 means an agent is called twice for a connection it did not answer the first time, when the daemon
restarts in between. The evals were not repeated: `integrations/` is the same as in build 62 (P5-23). opencode was
not connected, and the menu bar app was not looked at. The comparison in result 7 is one night and one morning of
one person's use. Every Touch ID, password and macOS dialog was the owner's.

**Date.** 16 November 2026.
