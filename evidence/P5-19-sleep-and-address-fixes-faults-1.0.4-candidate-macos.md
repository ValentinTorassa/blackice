# P5-19: the 1.0.4 candidate replaces 1.0.3 in place and passes the fault tests

**Claim.** A 1.0.4 candidate (build 36) replaced the published 1.0.3 in place, in ask mode, with no restart, and
passed all 29 checks of the fault tests on its second run. The first run passed 28: a switch to accept-all made from
the menu bar during case 4 came before the script's own. Build 36 fixes two faults found in 18 hours of 1.0.3 on the
owner's Mac: hooks the Mac slept through held every slot after their events had timed out, and approved connections
to hosts whose addresses rotate every few seconds were dropped as `approved;address_mismatch`. Both fixes were
checked by unit tests; neither fault was reproduced live on build 36. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, with the
router as its DNS server and Tailscale's DNS off for the fault tests.

**Build.** Blackice.app 1.0.4, build 36, from 946cea0, signed with the Developer ID Application of team M294LK997M,
notarized and stapled, `Blackice-1.0.4.zip` SHA-256 `7e8678f2d79322bb27361e6f290dc0c62efd1f651c40f3c39587c99d76b95a23`.

**Configuration.** The owner's file (24 rules, ask mode, Claude Code answering, the owner's notes), and for the fault
tests the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**What 1.0.3 did.** The filter's and the daemon's logs of 7 and 8 November, about 18 hours and 59,485 connections:

- From 02:51:59 to 03:03:35 four hooks held all 4 slots, and 4 events that came in meanwhile were dropped while
  waiting (`event_ended`). Each of the four had started just before the Mac slept. A hook's timeout is measured in
  time awake and an event's deadline in time of day, so after the wake each hook ran on for up to its full timeout
  although its event was over.
- 49 of mailctl's 2,407 approved connections to outlook.office365.com were dropped as `approved;address_mismatch`,
  each after an agent had approved it. That host's A records live 2 to 4 s and rotate: 13 answer sets in 3 minutes,
  and half of the first addresses seen were missing from answers up to 30 s old, the time blackice kept them.

**The fixes.**

1. The daemon also checks the time of day, so a hook the Mac slept through dies when the Mac wakes past its event's
   deadline (`HookRunner`, `wallClock`).
2. Answers 2 s old or older that miss a flow's address are looked up again before the address counts as a mismatch
   (`HostAddressCache.checkOrRefresh`).

**Run.** 8 November 2026, 16:04 to 16:51, and 9 November, 12:05 to 12:08 (UTC−3), from a Claude Code session on
the Mac.

1. The install script with `BLACKICE_ZIP` and `--force`, then `blackice start` (Touch ID).
2. `macos/scripts/fault-test.sh` (two Touch IDs), 8 November at 16:49 (`fault-test-36b.log`).
3. The same, 9 November at 12:05 (`fault-test-36c.log`).

**Result.**

1. `1.0.4/36 [activated enabled]`, no restart. The new extension took the owner's file in ask mode (generation 29);
   its first flow came 0.58 s after the old one's last.
2. 28 of 29 checks pass. The one that fails is case 4's "both connections were waiting before the change (0 of 2
   in the pending list)". The menu bar app's log shows an item chosen at 16:51:04 and a Touch ID context opened for
   it; the filter installed accept-all at 16:51:06, 4 s after the restarted daemon registered and before the script
   ran `blackice pending`. The script's own `blackice mode accept-all` then printed "Already in accept-all mode."
   The rest of case 4 passed: the 2 events were cancelled and 32 flows went on as `accept_all;configuration_changed`.
3. 29 of 29 checks pass. With no daemon the connection waits and is dropped at the deadline, 30 s in. The hung hook
   is killed at the deadline (`hook_killed:deadline` after 29,915 ms) and its connection dropped 30.1 s after the
   event. The burst raises one event for the 70 connections to example.org (64 held, 496 flows dropped as
   `ask_capacity`) and one for each of the 50 hosts; it runs at most 4 hooks, 46 wait for a slot, and none goes
   unrecorded (42 dropped while waiting). `curl` reaches pypi.org during the burst. launchd starts the killed daemon
   again, and the switch to accept-all, 7 s in, lets the 2 waiting connections go (71 flows) and cancels their
   events.

Decided by: the extension and the daemon.

**Also.** The unit tests (535) pass, four times with the cooperative pool cut to one thread
(`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) and once without. The new test for the first fix fails on 1.0.3's
`HookRunner` (the hook ran its full 30 s) and passes on build 36's in about 0.5 s.

**Limits.**

- The sleep was not reproduced live. On this Mac `pmset sleepnow` only turned the display off, and the third try,
  with the Apple menu's Sleep by hand, did not happen before its deadline. The unit test replaces the time of day
  instead.
- mailctl did not run while build 36 was in ask mode with the owner's file (about 23 minutes on 8 November), so the
  second fix was not seen on outlook.office365.com. In those minutes 1,034 flows were logged. Every
  `address_mismatch` came from Apple's services: geod, 2 asks and 2 approved drops, and cloudd, 1 and 1. A fresh
  lookup does not always return the address an app connects to, and those connections are still dropped.
- The menu bar's switch in run 1 came from the owner, not from the script, and was not repeated on purpose.

**Date.** 9 November 2026.
