# P5-21: the 1.0.6 candidate keeps its approvals across a stop, an upgrade and a restart, and slows a loop of dropped TCP connections

**Claim.** Three builds of 1.0.6, the last of them the candidate (build 40), brought the filter's approvals back
after `blackice stop`, after two upgrades in place and after a restart of the Mac, each with what it had left less
the time gone by. After that restart identityservicesd opened about 430 connections a second to a peer the filter
drops, and the filter used half a core. The candidate delays an app's TCP connections once 64 were dropped within
2 s: 12 loops from one program went from 5,452 tries in 10 s on build 39 to 184, and the extension from 51 % of a
core to 3 %. A UDP loop, and a TCP loop of 100 connections at once, still cost about 43 %, with their log lines
bounded. The fault tests on the candidate passed 23 of 29 checks, and the 6 that failed need example.com or
www.example.com, for which that network's DNS server answers NXDOMAIN. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on, FileVault on.
Wi-Fi, on two networks. For the fault tests Tailscale's DNS was off and the network's router was the DNS server.

**Builds.** Blackice.app 1.0.6, each signed with the Developer ID Application of team M294LK997M, notarized and
stapled:

- build 38, from e22fc15: the saved approvals and each app's share of the lookups;
- build 39, from 91d52aa: the delay of repeated drops, and what a review of the saved approvals found;
- build 40, from f432e06, the candidate: only TCP waits. `Blackice-1.0.6.zip` SHA-256
  `43dbe4277707c0d6ebe8f58ebed9419a49cda5eb7b8cf991d28654441c976a94`.

**Configuration.** The owner's file (24 rules, ask mode, Claude Code answering, the owner's notes), and for the fault
tests the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**What 1.0.5 did.** Approvals lived in the filter's memory, so `blackice stop`, an upgrade and a restart cleared them
and the agent was asked again (P5-20). The 1,024 places for connections waiting on a lookup had no share per app: in
two fault-test runs `nscurl`'s burst took them and `curl`'s connections were dropped as `lookup_capacity` (P5-20).
A dropped connection failed at once, however many the app had just had dropped.

**The change.**

- The filter saves its approvals to a file only root can read, when they change and once a minute, and at a stop
  after its XPC server is down. A start reads them back into an empty table, each with what it had left less the
  time gone by on the clock.
- One app holds at most 256 of the 1,024 lookup places; past that its connections are dropped as
  `lookup_capacity_app`.
- Once an app has had 64 TCP connections dropped within 2 s, its next ones that would be dropped wait 2 s first, at
  most 64 at once per app and 256 in all, and after 30 s the app is counted afresh. UDP flows do not wait: past
  the same count they get 8 log lines per 2 s, and `control drops_not_logged` counts the rest.

**Run.** 10 November 2026 (UTC−3), from Claude Code sessions on the Mac.

1. Build 38 over build 37 (1.0.5) with the install script, `BLACKICE_ZIP` and `--force`, then `blackice start`
   (Touch ID), at 01:50. Then `blackice stop` and `blackice start`, 01:51 to 01:59.
2. `macos/scripts/fault-test.sh` on build 38 at 02:09 (`fault-test-38b.log`; at 02:01 the first Touch ID went
   unanswered and nothing ran).
3. A restart of the Mac: it started at 07:59:33 and the owner logged in at 08:31.
4. Build 39 over 38 at 08:54, started at 08:57; build 40 over 39 at 09:12, started at 09:21. `blackice pending`
   before and after each.
5. Loops from two Python programs started from the session, on builds 38 to 40, with `log stream` on the
   filter's subsystem, `top` on the extension and a `curl` to pypi.org meanwhile: one opens a new UDP socket per
   datagram to 192.0.2.1 port 9, the other connects TCP to fe80::dead:beef port 9 on `en0`, from 1, 12 or 100
   threads. Ask mode drops both as `no_host`.
6. `curl --resolve github.com:443:1.1.1.1 https://github.com/`, with github.com approved for curl, on builds 39
   and 40.
7. `macos/scripts/fault-test.sh` on build 40 at 10:23, on the second network (`fault-test-40b.log`). At 09:49 it
   did not start: for half an hour the terminal's programs could not read the repository's folder.

**Result.**

1. Approvals came back each time. For the restart and the two upgrades, every pair in `blackice pending` before
   was in it after:

   | | Gone by | `control approvals_restored` |
   |---|---|---|
   | `blackice stop` and `start`, build 38 | 8 min | 3 |
   | Restart of the Mac, build 38 | 35 min | 16 |
   | Build 38 to 39 | 4 to 5 min | 112 |
   | Build 39 to 40 | 8 to 9 min | 126 |

   Each approval had that many minutes less to run, to the minute `blackice pending` shows. The upgrade from
   build 37 cleared them one last time: 1.0.5 saves none. A user's process cannot read the file
   (`Permission denied` under `/var/root`).
2. After the restart the filter started at 08:31:32, at the login, not at 07:59. From 08:31:50 identityservicesd
   opened TCP connections to a link-local peer on `utun4`, port 1024, each dropped as `no_host`: 2,616 in 6 s of
   `log stream` (about 430 a second). In its first 18 minutes the extension used 9 min 10 s of processor time
   and identityservicesd 3 min 7 s, a `curl` to github.com took 6 s once, and the system log kept so few of the
   filter's lines that `blackice report` counted 6,122 connections for the hour. There was no such connection in
   the 36 hours before. The loop stopped when build 39 replaced build 38, and identityservicesd has not tried
   since, so no build was seen to delay it.
3. The loops, each for 8 or 10 s:

   | Loop | Build | Tries | Logged | Extension | `curl` to pypi.org |
   |---|---|---|---|---|---|
   | UDP, 1 program | 38 | 1,234 in 8 s | 1,234 | 57.1 % | 0.06 s |
   | UDP, 1 program | 39 | 72 in 8 s | 72 | 3.1 % | 0.05 s |
   | UDP, 12 programs | 39 | 4,474 in 8 s | 88 | 50.1 % | 0.06 s |
   | UDP, 1 program | 40 | 4,151 in 8 s | 88 | 42.0 % | 0.06 s |
   | TCP, 1 thread | 39 | 74 in 10 s | 74 | 3.6 % | 0.05 s |
   | TCP, 12 threads | 39 | 5,452 in 10 s | 97 | 51.4 % | 0.06 s |
   | TCP, 1 thread | 40 | 74 in 10 s | 74 | 3.5 % | 0.05 s |
   | TCP, 12 threads | 40 | 184 in 10 s | 184 | 3.1 % | 0.05 s |
   | TCP, 100 threads | 40 | 5,713 in 10 s | 320 | 42.8 % | 0.63 s |

   On build 38 the UDP loop ran while identityservicesd's did. Build 39 delayed UDP flows too, 8 at once per app:
   `sendto()` returned within 0.1 ms and `close()` then took 1.00 s, which is what slowed the single UDP loop
   there; on build 40 `close()` takes 2 ms. In the TCP loops `connect()` failed with "No route to host" within
   0.1 ms whether the filter dropped the flow at once or paused it, and `close()` took 1.00 s on a paused one: the
   12 threads of build 40 tried 12 times a second for that reason, each waiting on its `close()`. Every try not
   logged was counted in `control drops_not_logged`.
4. On builds 39 and 40 the connection to 1.1.1.1 was dropped as `address_mismatch` within 0.06 s, with no event,
   and a plain `curl https://github.com/` went through on its approval (HTTP 200).
5. The fault tests:
   - Build 38, 28 of 29. In the burst 1,105 of `nscurl`'s connections were dropped as `lookup_capacity_app` and none
     of any app as `lookup_capacity`; `curl` reached pypi.org in 3 s. 34 of the 50 hosts raised an event, where
     the check wants 40. Case 4 passes with the change 30 s in.
   - Build 40, 23 of 29, on another network. All of cases 2 and 3 pass: the hung hook is killed after 29,751 ms
     and its connection dropped 30.7 s after the event; in the burst 50 of 50 hosts raise an event, at most 4
     hooks run, 46 wait for a slot, none goes unrecorded (42 dropped while waiting), no connection is dropped as
     `lookup_capacity` or `lookup_capacity_app`, and `curl` reaches pypi.org within a second. The 6 that fail are
     3 of case 1 and 3 of case 4, and each needs a connection to example.com or www.example.com: `nscurl` failed
     after 5 s with "A server with the specified hostname could not be found". That network's router answers
     NXDOMAIN for both names, and 1.1.1.1 and 8.8.8.8 resolve them. Case 4's other host passes: its event was
     cancelled by the change 8 s in, and 135 flows went on as `accept_all;configuration_changed`. During the run
     Tailscale's network extension, which the test's file has no rule for, had 241 flows logged as dropped
     `no_host`, three times 57 to 64 of them within one second, and 349 more were counted in
     `control drops_not_logged` in the seconds after those.
     The script now stops before the first Touch ID when a case's host does not resolve.

Decided by: the extension and the daemon.

**Also.** The unit tests (554) pass, once with the cooperative pool cut to one thread
(`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) and once without. An independent review of the saved approvals and the
lookup share (d828047 to e22fc15) led to three fixes in build 39: a deny that arrived during a stop could be
undone by the approvals saved just before it, a second start restored the file over a table in use, and a save
that failed was tried again every second. No crash report of blackice since 3 November.

**Limits.**

- The delay was not seen on the loop that prompted it: identityservicesd's stopped at the upgrade. In the TCP
  loops run here macOS failed `connect()` by itself, so what slowed them was `close()` waiting on the paused flow,
  not a program waiting for its connection to fail.
- The filter spends about 0.9 ms of processor time on a flow whatever it decides. A UDP loop, and a TCP loop with
  more than 64 connections at once, still cost half a core; the delay bounds their log lines only.
- An app past 64 dropped TCP connections within 2 s has each next drop wait 2 s, for up to 30 s at a time.
- Connections dropped for a full table (`lookup_capacity_app`, `ask_capacity`) are not counted towards the delay:
  in the bursts `nscurl` had 1,105 dropped at once as `lookup_capacity_app` on build 38 and 496 as `ask_capacity`
  on build 40.
- No fault-test run on the candidate passed cases 1 and 4 in full; they passed on build 38.
- The approvals stay through a change of configuration: the test's file ran with the approvals given under the
  owner's, 181 before the run and 171 after.
- Nothing forgets every approval any more: `blackice stop` used to, and `blackice deny` revokes one pair at a time.
- With FileVault on the filter starts at the login. Before that nothing is filtered.
- `mailctl list outlook` over IMAP, an approved pair, still loses connections to `address_mismatch`: 6 of 155 on
  build 37 with Tailscale's DNS (3.9 %), 15 of about 106 on build 38 with the router's (14 %), up to 6 in a row.
  mailctl never failed, since it goes on to the next address. The cause is not known.
- Whether identityservicesd's link to the iPhone should pass in ask mode is not decided.

**Date.** 10 November 2026.
