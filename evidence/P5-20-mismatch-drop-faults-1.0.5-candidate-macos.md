# P5-20: the 1.0.5 candidate drops a named pair's address mismatch at once; no fault-test run passes all 29

**Claim.** A 1.0.5 candidate (build 37) replaced the published 1.0.4 in place, with no restart. In ask mode it drops
at once a connection whose app and host a rule, the Apple services table or an approval names but whose address is
not among the host's answers. 1.0.4 raised an event for it that no answer could act on. In two hours of ask mode with
the owner's file, 48 such connections were dropped and none was asked about. In three fault-test runs every check
passed at least once and no run passed all 29: case 4's Touch ID came after the test's 30 s deadline in two of
them, and in the two after midnight the burst filled the 1,024 places for connections waiting on a lookup. A fourth
run never started, its first Touch ID unanswered. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, with the
router as its DNS server and Tailscale's DNS off for the fault tests.

**Build.** Blackice.app 1.0.5, build 37, from cdfc234, signed with the Developer ID Application of team M294LK997M,
notarized and stapled, `Blackice-1.0.5.zip` SHA-256 `7b73e48ea44902e362e677e36561ffffb8e08c2a76b966e3d7aabb8c51ac1fee`.

**Configuration.** The owner's file (24 rules, ask mode, Claude Code answering, the owner's notes), and for the fault
tests the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**What 1.0.4 did.** In 18 hours of 1.0.3 on this Mac, 100 events were raised for pairs already named, because the
connection's address was not among the host's answers. Each was approved and its connection dropped anyway, after
holding one of the 4 hook slots for about 3 s. 1.0.4 looks the host up again first, and still asks when the fresh
answers miss the address too. On build 36, `curl --resolve github.com:443:1.1.1.1 https://github.com/`, with
github.com approved for curl, raised an event (`ask address_mismatch`); Claude Code approved it 2.4 s later and the
connection was dropped as `approved;address_mismatch`. curl failed after 2.45 s.

**The change.** In ask mode, as in block-all, a named pair is dropped on a mismatch as `address_mismatch`
(`FilterPolicy.named`). A pair nothing names is still asked about, with its address marked as not matching: an
approval drops the waiting connection and lets the app's next one through once its address checks out.

**Run.** 9 and 10 November 2026 (UTC−3), from a Claude Code session on the Mac.

1. The install script with `BLACKICE_ZIP` and `--force`, then `blackice start` (Touch ID), at 12:37.
2. The same `curl` to 1.1.1.1 at 12:37:51, with 1.0.4's approvals gone, and at 12:38:11, after Claude Code had
   approved curl to github.com again.
3. Ask mode with the owner's file from 19:56:31 to 21:57:03, the Mac in normal use.
4. `macos/scripts/fault-test.sh` (two Touch IDs) at 23:02, 23:52, 00:12 and 00:20 (`fault-test-37.log`, `-37b`,
   `-37c`, `-37d`).

**Result.**

1. `1.0.5/37 [activated enabled]`, no restart, in ask mode with the owner's file.
2. With no approval, curl to github.com was asked about as `no_rule`. Claude Code approved it in 2 s, the waiting
   connection was dropped as `approved;address_mismatch`, and a plain `curl https://github.com/` then went through on
   that approval (HTTP 200). With the approval in place, the connection to 1.1.1.1 was dropped as `address_mismatch`
   0.02 s after it started, with no event.
3. 23,797 flows. 48 were dropped as `address_mismatch`, all from Apple's services (`dataaccessd` 13,
   `privatecloudcomputed` 8, `trustd` 7, `nsurlsessiond` 6, `cloudd` 4, `geod` 3, `syspolicyd` 2, `mobileassetd` 2,
   `tipsd`, `rtcreportingd` and `AddressBookSourceSync` 1 each), and none was asked about. One pair nothing named,
   nsurlsessiond to configuration.apple.com, was asked about and approved: 3 of its 4 waiting connections went on,
   the one whose address mismatched was dropped as `approved;address_mismatch`, and the next ones went through as
   `approval;server_name`. The daemon ran a hook for each of the 56 events and each answered. The extension used
   about 25 MB at the end.
4. The fault tests:
   - 23:02, 26 of 29. Cases 1 to 3 pass: the hung hook is killed after 29,605 ms and its connection dropped 30.6 s
     after the event; in the burst 47 of 50 hosts raise an event, at most 4 hooks run, 43 wait for a slot, none goes
     unrecorded (39 dropped while waiting), and `curl` reaches pypi.org in 1 s. Case 4's Touch ID went unanswered
     for 2 minutes, so the 2 waiting connections timed out at 30 s and the 3 checks after the change fail. The
     script's switch back went unanswered too, and the Mac stayed in ask mode with the test's file until the owner
     chose accept-all from the menu bar at 23:37.
   - 23:52: the first Touch ID went unanswered; nothing ran.
   - 00:12, 25 of 29. Case 4's change came 85 s in, after the events had timed out, so they were not cancelled. In
     the burst 305 connections were dropped as `lookup_capacity`, 8 of them `curl`'s, and the script's `curl` to
     pypi.org, which a rule allows, failed ("Couldn't connect to server" after 2,994 ms). The event for example.org
     held none of its connections when the script looked.
   - 00:20, 28 of 29. Case 4 passes with the change 14 s in: both events cancelled, 18 flows on as
     `accept_all;configuration_changed`. `curl` reaches pypi.org in 3 s and the example.org event holds 64
     connections, but 330 of the burst's connections were dropped as `lookup_capacity`, all of them `nscurl`'s, and
     28 of the 50 hosts raised an event, where the check wants 40.

Decided by: the extension and the daemon.

**Also.** The unit tests (535) pass, once with the cooperative pool cut to one thread
(`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) and once without. The tests that expected an ask on a named pair's
mismatch now expect the drop.

**Limits.**

- `lookup_capacity` dropped no connection in the burst at 23:02, nor on build 36 on 9 November, and about 300 in
  each run after midnight. Blackice's lookups were not timed, so whether they were slower then is not known. The
  lookup code is the same as 1.0.4's. In the two hours of normal use no connection was dropped that way. Recorded under
  "Lookups in a burst" in `docs/plan.md`.
- Case 4 needs its Touch ID within the 30 s the test's connections wait; it came later in two runs.
- Replacing the extension cleared its approvals, which live in its memory, so 1.0.5 asked again about apps and
  hosts 1.0.4 had approved.
- A connection dropped as `address_mismatch` raises no event, so the agent never hears of it; it is in the filter's
  log only.
- mailctl did not run during the two hours, so 1.0.4's fresh lookup was again not seen on outlook.office365.com.

**Date.** 10 November 2026.
