# P5-22: the 1.0.7 candidate keeps a new filter out of the kernel's hold at an upgrade, and ends the hold at an ICMP socket with an echo request

**Claim.** Build 58, the 1.0.7 candidate, replaced build 57 in place with the filter turned off first. The kernel
was at the ICMP socket of symptomsd that had held the three upgrades before it for 58.9, 47.3 and 116.0 s; `start`
sent an echo request to 127.0.0.1, and the kernel let go 0.42 s after the filter was turned off. The Mac never had
two filters, `start` said nothing of a wait, and a lookup a second took 0.13 s or less. Its `stop` did the same at
that socket, in 0.42 s. Nine replacements and two stops before it showed what holds a new filter (a filter the kernel is still disconnecting, registered for the same
control unit), that a filter going with none in its place holds nothing up, that waiting with the filter off spares
a hold at a UDP socket, that it does not spare one at that ICMP socket whether `start` waits 30 s or 90, and that a
`ping` of loopback ends that one within 0.01 s. The candidate's filter and daemon are build 47's: on build 55 a full
table of DNS flows cost no lookup, a link-local address was asked about, a title's token stayed out of the event,
and three kinds of loop were delayed or bounded; a mail CLI's listing ran 180 times with none failed and six
connections dropped as `address_mismatch` in one run. The fault tests passed 29 of 29 twice on build 55 and once on
the candidate, and `blackice deny --all` forgot its 43 approvals. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), kernel xnu-13432.1.9~1, arm64, System Integrity
Protection on, FileVault on. Wi-Fi, with Tailscale's resolver (100.100.100.100); for the fault tests Tailscale's DNS
was off and the network's router was the DNS server.

**Builds.** Blackice.app 1.0.7, each signed with the Developer ID Application of team M294LK997M, notarized and
stapled:

- builds 47, 49, 50 and 51, from bf5a369: the filter and the daemon of the candidate. From here to build 58 only
  the CLI's `start`, `stop` and `status` change (`Report.swift`, `FilterDisconnect.swift`, `KernelFilters.swift`,
  `NESystemControl.swift`, and their tests);
- build 52, from 397f09c: `start` and `status` say when macOS is still disconnecting a filter, and whose socket it
  waits on;
- build 53, from 1c7a98f: they say it only when another filter runs in the place of the one going, and `stop` says
  that macOS asks next;
- builds 54, from bbdc21c, and 55, from da3cac9 (the same code): an upgrade turns the filter off and waits for the
  kernel, 30 s at most, before it starts the new one;
- build 56, from 2bb550f: a `start` that finds the filter off waits the same way;
- build 57, from e21660e: the wait is 90 s;
- build 58, from 44f4148, the candidate: the echo request to loopback while `start` or `stop` waits.
  `Blackice-1.0.7.zip` SHA-256 `1e013215d2dd45b7acd25797d281f4eb5d69dc085ea0d4f56213005ea097e018`.

**Configuration.** The owner's file (24 rules, ask mode, Claude Code answering), and for the fault tests the script's
own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**What 1.0.6 did.** `start` replaced the extension with the filter on, so the new build's filter started while the
kernel was still disconnecting the old one. No replacement with builds 37 to 42 as the old filter was seen to stall:
flows went on 0.1 to 0.2 s later, and why none of those stalled is not known. From build 43 on, on 10 and 11
November, four of five did, for 16.3, 12.6, 4.1 and 25.8 s. `blackice stop` printed nothing between Touch ID and
macOS's own dialog to remove the extension.

**The change.**

- When macOS runs an older build and the filter is on, `start` turns the filter off after Touch ID, waits until the
  kernel's list of filters (`net.cfil.filter_list`) no longer has the old one, 90 s at most, and only then replaces
  the extension and turns the filter on. Connections are not checked meanwhile; once the wait has lasted a second
  `start` says so, with the process whose socket the kernel is at (`net.cfil.sock_list`). A `start` that finds the
  filter off waits the same way for a filter a `stop` left going.
- While it waits, `start` sends an ICMP echo request to 127.0.0.1 from a datagram ICMP socket, 0.3 s into a filter
  going and every 2 s after. `stop` does the same for 3 s at most after it turns the filter off.
- When a filter is still going beside one that runs with its control unit, `start` and `blackice status` (a
  `network` line) say that no new connection gets through and whose socket macOS waits on.
- `stop` says `macOS now asks you to confirm removing the network extension: follow its dialog.` before it asks
  macOS.

**Run.** 11 November 2026 (UTC−3), from a Claude Code session on the Mac. The owner ran each replacement and stop in
his own terminal and answered every Touch ID and macOS dialog. A replacement is the install script with
`BLACKICE_ZIP` and `--force`, then `blackice start`. A watch ran through each: `log stream` on the filter and on
nesessionmanager, the kernel's lists of filters and of filtered sockets ten times a second, and the lookup of a new
name each second.

1. Builds 47 to 49 at 08:49 and 49 to 50 at 09:26, with a spindump of the first.
2. Builds 50 to 51 at 09:44 and 51 to 52 at 10:09, with a test program (`oneflow-hold.py`) holding one UDP socket,
   loopback traffic only, in the state the kernel does not get past: a datagram to one address every 5 s, one
   datagram to another at the start, whose flow the kernel collects.
3. `blackice stop` on build 52 at 10:26 with that socket open, then `blackice start`.
4. Builds 52 to 53 at 10:51 and 53 to 54 at 11:29 with that socket, closed 10 s after the old filter stopped.
5. Builds 54 to 55 at 12:03.
6. On build 55, from 12:09 to 13:05: a burst of 700 lookups with a connection to a new host before and after it; a
   TCP connection to `fe80::dead:beef` on `en0`; `node` and `npm` with titles written over their command lines, one
   with a token; loops of connections dropped as they start (TCP from 1, 12 and 100 threads, UDP) and of TLS hellos
   to an address that mismatches, each with a `curl` to pypi.org meanwhile; and a mail CLI listing a mailbox over
   IMAP every 10 s for 40 minutes.
7. `macos/scripts/fault-test.sh` on build 55 at 13:20 and at 13:26.
8. Builds 55 to 56 at 13:42 and 56 to 57 at 13:56.
9. `blackice stop` and `blackice start` on build 57 at 14:09, with `hold-ping.py`: once the kernel has been at a
   filter it is disconnecting for 8 s, one `ping -c 1` at a time, to 127.0.0.1 first.
10. Builds 57 to 58 at 14:25.
11. `macos/scripts/fault-test.sh` on build 58 at 14:35.
12. `blackice stop` and `blackice start` on build 58 at 14:48.
13. `blackice deny --all` on build 58 at 14:57, with `blackice status` and `blackice pending` before and after.

**Result.**

1. Two filters at once is what stalls. In 47 to 49 the kernel listed both from 08:49:08.74 to 08:49:12.53, the four
   lookups started in that time all ended within 0.2 s of its end, and the old extension's thread ran in the kernel
   under `close()` for 414 samples in a row, 4.14 s of processor time; its own stop had taken 1 ms. 49 to 50 had no
   second filter in any reading and no stall.
2. The test socket holds it. In 50 to 51 the kernel had two filters from 09:44:40.07 to 09:44:49.98, the socket
   closed at 09:44:49.987, and the nine lookups started meanwhile ended by 09:44:50.24; the first socket still on
   the old filter was the test's in every reading. 51 to 52 was held 25.8 s at a UDP socket of Tailscale's network
   extension: in its first 5 s the filter going went from 13 sockets to 31 while the new one went from none to 18.
3. A stop is held and holds nothing up. On build 52 the kernel listed the filter as going, alone, for 10.1 s; it
   kept its 15 sockets and got no new one, and a lookup a second took 0.21 s at most. `stop` came back 78 s later:
   macOS had asked an administrator to confirm (authorization right `com.apple.system-extensions.admin`) and
   blackice had printed nothing.
4. Waiting with the filter off spares a hold at a UDP socket:

   | | 52 to 53, filter left on | 53 to 54, filter turned off first |
   |---|---|---|
   | Old filter stopped | 10:51:12.04 | 11:29:34.91 |
   | Test socket closed | 10:51:22.32 | 11:29:45.10 |
   | Two filters in the kernel's list | 9.8 s | never |
   | No filter | never | 10.5 s |
   | Lookups started meanwhile | waited 9.83 s down to 0.80 s | 0.13 s at most |

   In 53 to 54 `start` said, a second in, `macOS is still disconnecting the filter that was running. Until it is
   done blackice stays off and connections are not checked, for 30 s at most.` and `It waits on a UDP socket of
   Python (pid 80799)`, and build 54's filter started with the configuration `start` had saved.
5. It does not spare a hold at symptomsd's ICMP socket (pid 14332, bound to no address: `netstat -anv` lists it as
   `icm4 *.* *.*`), which was first on the old filter's list in each of these:

   | | 54 to 55 | 55 to 56 | 56 to 57 |
   |---|---|---|---|
   | `start` waited | 30 s | 30 s | 90 s |
   | Kernel at it | 58.9 s | 47.3 s | 116.0 s |
   | Two filters, no new connection | 28.5 s | 17.0 s | 25.8 s |
   | Lookups with the filter off | 28, 0.12 s at most | 30, 0.10 s at most | 90, 0.13 s at most |
   | Longest lookup past the wait | 30.0 s | 17.5 s | 26.4 s |

   Each time `start` named symptomsd a second in, said `macOS is not done after 30 s. Starting the filter anyway.`
   (90 s in the third), and said with `blackice status` that no new connection got through until the kernel let
   go. No byte of that socket's record in the kernel's list changed during a hold; in the second and the third the
   record began again with 180 bytes within 0.3 s of the kernel letting go.
6. A ping ends it. In the stop on build 57 the filter was going from 14:09:40.58, with symptomsd's socket first on
   it. `stop` printed its line about macOS's dialog at 14:09:40.61 and was back at 14:09:42.62, the kernel still
   at it, and `blackice status` said only `blackice is off`. At 14:09:48.617, 8.0 s in, `ping -c 1 127.0.0.1` got
   its reply, and at 14:09:48.623 the kernel listed no filter. The `start` that followed had its filter in the
   kernel's list at 14:10:09.51, 29 s after that hold began.
7. The candidate's `start` ends it by itself. In 57 to 58 the kernel listed build 57's filter as going, 21 sockets
   on it and symptomsd's first, in the readings of 14:25:43.145 to 14:25:43.458, no filter at 14:25:43.560, and
   build 58's from 14:25:44.079. `start` printed `Touch ID to start filtering…` and then `✓ blackice is on in ask
   mode, Claude Code answers`, with nothing between, and `blackice status` had no `network` line. The lookup
   started at 14:25:43.78 took 0.02 s, and none in the minute around it over 0.13 s.
8. The other changes, on build 55:
   - After 700 lookups in 12.5 s, which the filter logged as 1,411 resolver flows, a connection to a host looked up
     for the first time was decided with no lookup by the filter itself.
   - The connection to `fe80::dead:beef` raised an event that names the address (the agent denied it).
   - `npm view --registry=… -- --token … left-pad`, whose title `ps` showed as `npm view --token … left-pad`,
     raised an event with `title` `npm view` and no script, and the token was in no event. While another `npm
     view` waited, `blackice pending` showed `calls itself npm view`.
   - TCP loops of connections the filter drops as they start: 75 tries in 10 s from 1 thread, 184 from 12 (76 in
     the first second, then 12 a second) with the extension at 1 % of a core or less, and 5,867 from 100 threads with
     322 logged, 5,545 counted in `control drops_not_logged` and the extension at 47.5 %. The UDP loop: 4,439 tries
     in 8 s, 88 logged, the extension at 43.6 %.
   - 12 programs retrying a TLS connection to an address that mismatches its approved host made 112 tries in 10 s
     (76 in the first second, then 12 every 3 s), all dropped as `address_mismatch`, none uncounted; a `curl` to
     the host itself returned 200 in 0.12 s meanwhile.
   - The mail CLI's 180 listings all succeeded: 626 flows, 6 of them dropped as `address_mismatch`, all in one run
     (12:46:49.372 to 12:46:49.378, to login.microsoftonline.com), 5 ms after the resolver had that host's
     addresses anew; the run's next connection passed. The filter looked a host up itself twice in the 40 minutes.
   - In build 55's first hour of ask mode (12:04 to 13:04): 13,833 flow lines, 25 of them `address_mismatch`, the 6
     above and 19 of Apple daemons.
9. The fault tests on build 55, 29 of 29 both times. At 13:20: the connection with no daemon waited in the pending
   list and was dropped at the deadline, 30 s in; the hung hook was killed after 29,301 ms and its connection
   dropped 30.2 s after the event; in the burst 50 of 50 hosts raised an event, at most 4 hooks ran, 46 waited for
   a slot, none went unrecorded (42 dropped while waiting), 128 connections past 64 an event were dropped as
   `ask_capacity` and 54 as `ask_capacity_app`, and `curl` reached pypi.org within a second; the change of
   configuration 19 s in cancelled both waiting events. At 13:26: 43 of 50 hosts raised an event, where the check
   wants 40, the hook was killed after 29,371 ms, 21 connections were dropped as `ask_capacity_app`, and the rest
   as before.
10. The fault tests on build 58 at 14:35, 29 of 29: the hung hook was killed after 29,838 ms and its connection
    dropped 30.8 s after the event; in the burst 40 of 50 hosts raised an event, the fewest the check accepts, at
    most 4 hooks ran, 36 waited for a slot and none went unrecorded (32 dropped while waiting); 128 connections
    were dropped as `ask_capacity` and 29 as `ask_capacity_app`; `curl` reached pypi.org within a second; and the
    change of configuration 24 s in cancelled both waiting events.
11. The candidate's `stop` ends it too. The kernel listed build 58's filter as going, 38 sockets on it and
    symptomsd's first, in the readings of 14:48:28.722 to 14:48:29.036, and no filter at 14:48:29.139. `stop`
    printed its line about macOS's dialog at 14:48:29.22 and `✓ blackice is off` at 14:48:31.32, with no filter in
    the kernel's list. The `start` that followed asked for the extension to be allowed in System Settings, loaded
    the owner's file and had its filter in the list at 14:49:25.16: ask mode, 24 rules, the 43 approvals of before.
12. `blackice deny --all` asked for Touch ID and printed `✓ Forgot 43 approvals`; the filter logged `control answer
    forget touch_id forgotten 43` at 14:57:28.009. `blackice status` had 44 approvals four minutes before and no
    `approvals` row after, and `blackice pending` said `Nothing waiting, and no approvals.`

Decided by: the kernel, the CLI's `start` and `stop`, the extension and the daemon.

**Also.** The unit tests (592) pass. The stall's cause at a UDP socket was read in the kernel on disk (the same
build): adding a flow to a socket's table points a shortcut for tables of one flow at the new flow, removing a flow
clears the shortcut when it pointed at that flow, and with one flow left the lookup by id reads the shortcut alone;
the disconnect loop, told there is no flow, leaves the socket on the filter's list and takes the first again. The
xnu source Apple publishes attaches a new socket to every registered filter whose control unit its policy names,
with no test of the going flag (`cfil_info_attach_unit`).

**Limits.**

- One Mac, one version of macOS. The kernel's lists are laid out as `struct cfil_filter_stat` and `struct
  cfil_sock_stat`, which no documentation fixes: where they are laid out another way `start` upgrades as 1.0.6 did,
  with no wait and no echo request.
- An echo request ended the hold in three trials (a `ping` by hand, the candidate's `start`, its `stop`), all at
  the same socket of the same process. Why the kernel stays at that socket was not read in its code, and an ICMPv6
  socket was not tried.
- A hold at a UDP socket is not ended. `start` waits up to 90 s with the filter off, then starts the filter anyway,
  and no new connection gets through until the kernel lets go; that case was seen with a wait of 30 s only, at the
  ICMP socket.
- While `start` waits, connections are not checked, and a socket opened then is attached to no filter while it
  lives, like any socket open before a start.
- The wait of a `start` after a `stop` was not seen: in both runs the echo request had ended the hold before
  `start` saved its filter.
- After `blackice deny --all` no stop or restart followed, so that the saved file brings no approval back was not
  seen; nothing waited when it ran, so that what waits keeps waiting was not seen either. The unit tests cover both.
- The saved UDP destinations, for a VPN across a restart of the filter, were run on build 46 on 10 November and not
  again on the candidate; this entry does not record those runs.
- Six `address_mismatch` drops of an approved host in one run of 180 have no known cause. On 10 November, on build
  43 and another network, the same 180 runs had none.
- The burst of 700 lookups took 12.5 s; on 10 November, on another network, 1.5 s. Why is not known.
- `blackice stop` forgets a switch of the answering agent made with `blackice mode`: the next `start` reads the
  file again.
- Seen and not looked into: the filter drops mDNSResponder's own multicast queries (224.0.0.251 and ff02::fb, port
  5353) as `no_host`, 67 in an hour; and on one UDP socket that sent a datagram to each of 20 addresses with no
  name, 18 were dropped as `no_host` and the 19th `sendto` never returned.

**Date.** 11 November 2026.
