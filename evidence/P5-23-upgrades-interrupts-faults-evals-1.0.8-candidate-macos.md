# P5-23: the 1.0.8 candidate upgrades from 1.0.7 and from itself, survives a stopped start, and passes the fault tests and the evals

**Claim.** Build 62, the 1.0.8 candidate, and builds 59 to 61 before it upgraded 1.0.7 in place and each other with
the owner's configuration loaded every time. An upgrade's `start` stopped with one Control-C while the kernel was at
a test socket waited for the socket to close, turned the old filter back on and exited with 130; with two it turned
it on at once. A Control-C or no answer at Touch ID changed nothing. A SIGTERM stopped the daemon's running hook in
0.07 s. With the app replaced and no `start` yet, the daemon of build 62 said so every 10 s, where build 61's said
only that the connection ended. The fault tests passed 29 of 29 on builds 61 and 62. With build 62's instructions fx
decided the eval as expected (44 of 44, 12 of 12 with notes), and denied case 42 in 10 runs of 10 where build 61's
instructions let it approve 6 of 10. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), kernel xnu-13432.1.9~1, arm64, System Integrity
Protection on, FileVault on. Wi-Fi, with Tailscale's resolver (100.100.100.100); for the fault tests Tailscale's DNS
was off and the network's router was the DNS server.

**Builds.** Blackice.app 1.0.8, each signed with the Developer ID Application of team M294LK997M and notarized;
`spctl` accepted each as `source=Notarized Developer ID`, and the app's and the extension's Info.plist name the
commit (`BlackiceSourceCommit`):

- builds 59, 60 and 61, from 0063cb3: the same code, numbered apart so that each step is an upgrade.
  `Blackice-1.0.8.zip` SHA-256 `aa02183b…e696`, `14adc62a…1bc0` and `36595bb8…33bf`;
- build 62, from 9e74d2c, the candidate: 0063cb3 with one sentence more in the agents' instructions (a program with
  a `cdhash` in a vendor's own hidden folder is denied even at its vendor's host) and the daemon's line about an
  unfinished upgrade. `Blackice-1.0.8.zip` SHA-256
  `c70aa09a237631e4362d6a6ac3fb3c518af53833cbcaf9b49e2b6eace4835424`.

Before signing, build 62's tree passed the steps of `.github/workflows/ci.yml` on this Mac: `swift build
-Xswiftc -warnings-as-errors`, `macos/test.sh` (651 tests in 76 suites), `macos/smoke.sh`, and `sign.sh`,
`package.sh` and `fault-test.sh` with `DRY=1`.

**Configuration.** The owner's file: ask mode, fx answering (Claude Code and Codex also connected), 60 s to answer,
24 rules, and 25 from the owner's new file, loaded after the fault tests on build 61. For the fault tests the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to
answer).

**Run.** 15 November 2026 (UTC−3), from a Claude Code session over ssh. The owner answered every Touch ID at the
Mac. A replacement is the install script with `BLACKICE_ZIP` and `--force`, then `blackice start`, which ran in a
pseudo-terminal of its own so that a Control-C could be typed into it as a Terminal tab sends it. The kernel was
held with `hold-udp.py`: one UDP socket, loopback only, in the state the kernel does not get past while it
disconnects a filter (P5-22), closed 10 s after the first Control-C, or 4 s after the second.

1. The eval (`integrations/eval/run.sh`) with fx on case 42, from 09:23, with build 61's `integrations/` and with a
   copy that has build 62's sentence; nothing installed changes.
2. 1.0.7 (build 58) to 59 at 09:24, with `answers` switched to fx by `blackice mode` and the file saying Claude Code.
3. `blackice mode ask --agent codex` on 59, then 59 to 60 at 09:33, with the file now saying fx.
4. 60 to 61 at 09:34, stopped with Control-C at Touch ID; at 09:39 again, with Touch ID left unanswered.
5. SIGTERM to the daemon while a hook ran, on 60's extension; the daemon launchd started next was 61's.
6. 60 to 61 at 10:05, then `macos/scripts/fault-test.sh` at 10:07, then the owner's new file with 25 rules.
7. Build 62 built, signed and notarized at 18:07, then 61 to 62 at 18:09 with Touch ID left unanswered; the daemon
   restarted with `launchctl kickstart -k` in that state.
8. 61 to 62 at 18:27 with the socket held, one Control-C; at 18:30 the same, two Control-Cs; at 18:31 with no
   socket held.
9. `macos/scripts/fault-test.sh` on 62 at 18:31, then the owner's file.
10. On 62: SIGTERM to the daemon while a hook ran, `blackice approve` and `blackice deny` for curl and example.com,
    `blackice mode ask --agent codex` and back to fx, and the evals with fx and Codex; from 18:46 the owner ran the
    eval with Claude Code in his own terminal, then its cases with notes.

**Result.**

1. Every upgrade without a held socket loaded the owner's file and said nothing of a wait: `start` printed the switch
   it dropped (`fx answers now, switched with blackice mode or the menu; blackice.toml has Claude Code, and this
   start loads it.` on 59), `Touch ID to start filtering in ask mode, 24 rules, 1 hook, 60 s to answer…` and
   `✓ blackice is on in ask mode, fx answers`. The record of 1.0.7 to 59 ends at Touch ID: the ssh session that ran
   it dropped as the filter changed, and `blackice status` then said `on in ask mode` with the file's configuration.
2. Stopped before the filter changed, `start` changed nothing. A Control-C at Touch ID ended it with build 60's
   filter on; no answer for 2 minutes printed `No answer to Touch ID within 2 minutes, so nothing changed.` and exit
   77, on 61 and on 62.
3. Stopped while the kernel was at the held socket, it turned the old filter back on with its configuration:

   | | 18:27, one Control-C | 18:30, two Control-Cs |
   |---|---|---|
   | `start` named the socket | `It waits on a UDP socket of Python (pid 21715)` | `(pid 23797)` |
   | First Control-C | 18:28:47, `Waiting for macOS to let the old filter go before turning blackice back on; press Control-C again to turn it on now.` | 18:30:58, the same |
   | Second Control-C | none | 18:30:59 |
   | Filter back on | after the socket closed at 18:28:57.9 | at once, before the socket closed at 18:31:04.0 |
   | Exit | 130 | 130 |

   Each time `start` ended with `blackice start was stopped before it finished, so it turned blackice's filter back
   on with the configuration it had. Run blackice start again.`, `blackice status` said `on in ask mode` with
   `filter still build 61, and this app is build 62: blackice start finishes the upgrade`, and the extension stayed
   build 61. The `start` at 18:31 replaced it with build 62 and printed no wait; the daemon registered 10 s later
   (`configuration generation 10, 1 hook, timeout 60 s`).
4. Between the replacement of the app and its `start`, no hook ran: the daemon of the new build looks up its own
   build's XPC service, which the running extension does not offer, and launchd restarted it every 10 s. Build 61's
   daemon, against build 60's extension, wrote only `the connection to the network extension ended; exiting so
   launchd restarts it` and `registration failed: cannot reach the network extension (NSCocoaErrorDomain 4099)`.
   Build 62's, against build 61's, also wrote, each time:

   ```text
   2026-11-15T21:11:53.174Z [18656] blackice daemon: blackice was upgraded to build 62, but macOS still runs build 61's network extension. blackice start finishes the upgrade. Until then no hook runs.
   ```

   `blackice pending` said the same, with `Cannot reach blackice's filter.` first, and exited with 69.
5. A SIGTERM stops the running hooks. On build 62, curl's connection to paste.ee raised `ev-f0eb8585` at
   21:34:38.899Z and its hook started 14 ms later; the SIGTERM came at 21:34:40.341Z:

   ```text
   2026-11-15T21:34:40.341Z [25584] blackice daemon: SIGTERM: stopping 1 running hooks and 0 waiting, then exiting
   {"duration_ms":1511,"event":"ev-f0eb8585","hook_line":141,"reason":"daemon_stopping","signal":15,"ts":"2026-11-15T21:34:40.412Z","type":"hook_killed"}
   2026-11-15T21:34:40.477Z [26099] blackice daemon: registered with the network extension; configuration generation 13, 1 hook, timeout 60 s
   ```

   The connection was not sent again to the new daemon: it waited for its deadline and curl failed after 60.2 s.
   On build 60 the same had stopped the hook 415 ms after it started.
6. The fault tests passed 29 of 29 on build 61 (work files `blackice-fault-20261115-100705`) and on build 62
   (`blackice-fault-20261115-183145`): a connection waits and is dropped at its deadline with no daemon, a hung hook
   is killed at the deadline, a burst of 50 hosts and 70 connections to one host runs at most 4 hooks with the rest
   queued or dropped and none unrecorded, curl reaches pypi.org and `blackice status` answers during the burst, and
   a daemon killed with SIGKILL comes back, registers within 1 s and runs the hooks of connections that arrive
   after. The test's hung hooks made the daemon write `hooks_failing` (`count` 3, `reason` `no_line`) at 21:33:18Z,
   and `hooks_recovered` (`after` 8) followed when Codex answered at 21:38:15Z.
7. On build 62, `blackice approve --app com.apple.curl --host example.com --for 10m` let curl through (HTTP 200
   in 0.12 s), and `blackice deny` for the same app and host removed the approval: curl failed in 0.04 s.
   `blackice mode ask --agent codex` made Codex answer (it denied curl to pastebin.com in 2.8 s) and `status` said
   `Codex (switched with blackice mode or the menu; blackice.toml has fx)`; switching back to fx cleared that.
8. The eval, 51 events, with the instructions and the notes as `blackice agent connect` passes them:

   | Agent | Instructions | Cases | As expected |
   |---|---|---|---|
   | fx (`anthropic/claude-haiku-5.5`) | build 61's | 42, 10 runs | 4 of 10: 6 `approve 1h` |
   | fx | build 61's with build 62's sentence | 42, 10 runs | 10 of 10 |
   | fx | build 62's | all 44 | 44 of 44, median 2.9 s |
   | fx | build 62's | 12 with notes | 12 of 12 |
   | fx | build 62's | 38 to 44, 5 runs | 35 of 35, each case the same every time |
   | Claude Code (`haiku`) | build 62's | all 44 | 44 of 44, median 2.1 s |
   | Claude Code | build 62's | 12 with notes | 12 of 12 |
   | Codex (`gpt-6-luna`) | build 62's | all 44 | 43 of 44: it denied case 43 |
   | Codex | build 62's | 12 with notes | 11 of 12: it denied case 44 |
   | Codex | build 61's / 62's | 43, 5 runs | 5 of 5 / 5 of 5 |
   | Codex | build 61's / 62's | 44 with notes, 5 runs | 4 of 5 / 5 of 5 |

   A first Codex run, from 18:06, got no answer within 60 s on cases 1 to 19 and then answered the rest in 4.5 s at
   the median. The event log has no event of Codex's in that time and `blackice report` no dropped connection of
   it, so the filter did not hold it up; the cause was not found, and that run is not counted. The run from 18:35 had
   no timeout.

**Limits.** One Mac, macOS 27.0.1. opencode's eval was not run on build 62's instructions (opencode was not connected). The menu bar
app reopened with build 62 but was not looked at. `blackice stop` and a first install of build 62 were not run, and
neither was the Homebrew cask, which needs the published zip. A connection whose hook a SIGTERM stopped waits for its
deadline. Every Touch ID was the owner's.

**Date.** 15 November 2026.
