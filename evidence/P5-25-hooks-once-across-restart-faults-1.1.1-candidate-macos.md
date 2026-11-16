# P5-25: the 1.1.1 candidate runs no hook again for an event the daemon before it had run it for

**Claim.** On build 66, the 1.1.1 candidate, a daemon that launchd started again after a kill was sent nine events
whose hook the daemon before it had already run to its end with no answer (`events_sent_again 9 of 9`), and it
skipped all nine (`hooks_skipped`, `already_ran`) 8 ms after it registered. No event's hook started twice in the
run. On the 1.1.0 candidate the same restart ran the hook a second time for each such event (P5-24, result 9). The
fault test's 29 checks pass on build 66, and this time its printed list was kept. Build 66 replaced the published
1.1.0 after Homebrew had removed the app and the daemon's LaunchAgent, and its `start` loaded the daemon again.
The other change of 1.1.1, a menu bar app that quits instead of opening another build that is in quarantine, ran
in no step here: only unit tests have it. Phases 4 and 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on, FileVault on.
Wi-Fi. The network's router does not resolve example.com or www.example.com, so for the fault test the Wi-Fi
service's DNS server was 1.1.1.1.

**Builds.** Each signed with the Developer ID Application of team M294LK997M and notarized:

- 1.1.0 (build 65), as published: the Homebrew cask;
- build 66, Blackice.app 1.1.1 from ce80765, the candidate: 1.1.0 with a daemon that skips the events the one
  before it ended, a menu bar app that does not open another build in quarantine, and the first start's question
  in other words. `spctl` accepted it as `source=Notarized Developer ID`. `Blackice-1.1.1.zip` SHA-256
  `d1d6f8f294015ce56fd1a0e0a785faead7e7e904cdf31c8d72fae3f1d8ba1e65`.

Build 66's tree differs from the one CI passed on before the signing (50f9b08, run 43942297656) only in the
version of the two Info.plist files. CI passed on the release branch afterwards (65af60a, run 43962807614), and
that tree passed the steps of `.github/workflows/ci.yml` on this Mac: `swift build -Xswiftc -warnings-as-errors`,
`macos/test.sh` (662 tests in 77 suites), `macos/smoke.sh`, and `sign.sh`, `package.sh` and `fault-test.sh` with
`DRY=1`.

**Configuration.** The owner's file: ask mode, fx answering (Claude Code and Codex also connected), 60 s to answer,
25 rules, 1 hook. For the fault test the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**Run.** 16 November 2026 (UTC−3). The owner ran both steps in his own terminal, from scripts that run each
command and keep its output, and answered every Touch ID and Homebrew's password prompt. A Claude Code session on
the Mac built and signed build 66 and read the logs. A replacement with a build that is not published is the
install script with `BLACKICE_ZIP` and `--force`.

1. 18:52:26, on the published 1.1.0 installed with Homebrew: `brew uninstall --cask`, which runs the cask's
   `uninstall launchctl:` as `brew upgrade` does; build 66 from the install script; `blackice start`;
   `blackice status`; `curl https://www.ietf.org/`.
2. 18:53:19, on 66: `macos/scripts/fault-test.sh` from 65af60a, with 1.1.1.1 as the Wi-Fi service's DNS server
   for the run, under `script`, which kept everything it printed.

**Results.**

1. Build 66 over the published 1.1.0. `brew uninstall` printed `Removing launchctl service
   com.valentorassa.blackice.daemon` and asked for the password. After it launchd no longer had the daemon, its
   LaunchAgent file was gone, and 1.1.0's extension (build 65) was still activated. The install script checked the
   zip against its pin, the signature, the notarization and the version (1.1.1, build 66). `blackice start`
   printed:

   ```text
   Touch ID to start filtering in ask mode, 25 rules, 1 hook, 60 s to answer…
   ✓ blackice is on in ask mode, fx answers
   ✓ The daemon runs your hooks, now and at each login (logs in ~/Library/Logs/blackice)
   ```

   launchd had the daemon again and its LaunchAgent file was back; the daemon registered at 18:52:42.275 and
   loaded configuration generation 3; `systemextensionsctl list` had the filter 1.1.1/66 `[activated enabled]`;
   `status` said ask mode, fx, 25 rules and 131 approvals. One event was raised with the owner's configuration
   before the fault test, at 18:53:07, and fx denied it after 4.1 s.

   curl got HTTP 200 in 0.32 s and did not wait: fx's approval of 14:20 for curl and that host, given for 24 h
   (P5-24, step 7), still held, and no event was raised. So that command shows no answer by fx on build 66.

2. The menu bar app of 1.1.0, still running, opened the new app at 18:52:41.316 (`LaunchServices.launchViaCSUA`
   from its pid), as it does after any upgrade. The copy the install script makes has no `com.apple.quarantine`,
   and syspolicyd logged no question and no rejection. This is 1.1.0's menu bar app and an app out of quarantine:
   it is not the case 1.1.1 changes.

3. The fault test: 29 of 29 checks pass.

   - Daemon down: the connection to example.com waited in the pending list, the filter logged `control
     event_not_sent no_daemon` (11 times) and no event reached the event log; the flow was dropped at the
     deadline, 30 s in.
   - Hook hung: the daemon received the event, killed the hook at the deadline (`hook_killed`, `deadline`, after
     29287 ms) and the connection was dropped 30.3 s after the event; the hook's `sleep` was gone.
   - Burst: 70 connections to example.org shared one event, which held 64; the filter dropped the connections
     over 64 per event (`flow drop ask_capacity`, 186); 50 of 50 distinct hosts raised an event; at most 3 hooks
     ran at once, under the limit of 4; 46 hooks waited for a slot and 42 were dropped while waiting; every event
     has a record of its hook. curl reached pypi.org through its rule during the burst (HTTP 200), `blackice
     status` answered, and the daemon refused no hook.
   - Restart: `launchctl kill 9` on the daemon (pid 45115); launchd started pid 45892, which registered within
     1 s and ran the hook for the two events the test raised after it.
   - Configuration change: both connections were in the pending list; the switch to accept-all, 8 s in, let the
     paused connections go (`flow allow accept_all;configuration_changed`, 50) and cancelled the two events.

4. A daemon that starts again runs no hook again for the events the one before it ended. When pid 45892
   registered, at 18:55:07.490, the filter logged `control events_sent_again 9 of 9`. The nine were events of
   other apps' connections, received by pid 45115 between 18:54:40 and 18:54:59 with 30 s to their deadline, for
   which the test hook had exited with status 0 and no answer (`hook_no_answer`, `no_line`). The new daemon wrote
   for each, at 18:55:07.498 and 18:55:07.499:

   ```text
   {"event":"ev-…","reason":"already_ran","ts":"2026-11-16T21:55:07.498Z","type":"hooks_skipped"}
   ```

   and no `event_received` and no `hook_started`. In the whole test, 87 events and 44 hooks started, no event has
   two `hook_started`. Two of the nine were dropped at their deadline, at 18:55:11, and the other seven were
   cancelled at 18:55:16 by the test's switch to accept-all.

**Limits.** One Mac, macOS 27.0.1. The cases in which a new daemon does run an event's hooks again happened in no
step: a hook the daemon's own end stopped (`daemon_stopping`), a hook with no end in the log, and an answer that
did not reach the extension. Unit tests have them, and P5-24 has the first on build 65, before this change. The
menu bar app's check ran in no step: it acts in the build that an upgrade replaces, and only when the new app is
in quarantine, so the first upgrade that can show it is Homebrew's from 1.1.1 to the version after; Homebrew's
upgrade from 1.1.0 to 1.1.1 still has 1.1.0's menu bar app (P5-24, result 11). The owner's configuration ran on
build 66 for 37 s before the fault test, with one event; there is no stretch of use. The first start's question
was not looked at on the screen. The evals were not repeated: `integrations/` is the same as in build 62
(P5-23). opencode was not connected.
