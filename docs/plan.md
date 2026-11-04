# Plan

blackice is early: 0.3.2 is its current release ([`CHANGELOG.md`](../CHANGELOG.md)), and it has run on one Mac. This file holds the phases, the decisions
taken so far and the open problems. A phase is done when its check passes on a real Mac, not when the code compiles,
and each run on a Mac is recorded in [`evidence/`](../evidence/).

## Decisions

| Topic | Decision |
|---|---|
| Name | The product ships as blackice (decided on 2 November 2026). The first proof of concept, also called blackice, is archived as [ValentinTorassa/blackice-poc](https://github.com/ValentinTorassa/blackice-poc). |
| Repository | Its own repo. Swift files come from blackice-poc's macOS app filter, with the source commit noted in each file. |
| Language | Swift for the extension, the CLI and the daemon. |
| Ask mode | Asks only about connections that no rule or current approval covers. |
| No answer in time | Deny after N seconds. N is configurable. macOS keeps a paused TCP flow as long as we want, so what bounds N is how long the app and the server wait (see the open problems). |
| Approval scope | One app (by signing identity) and one host, with an expiry: `blackice approve --app … --host … --for 1h`. |
| Ad hoc signed code | Ask mode asks about it too, and the approval names its cdhash plus the host: `blackice approve --cdhash … --host …`. A rebuild changes the cdhash, so the next connection asks again. Rules in `blackice.toml` never name it, so block-all drops it. Code with no signature has no cdhash either and is dropped. |
| Host and address | Before a rule or an approval counts, the host is resolved with the system resolver and the flow's remote address must be among the answers, which are kept for 30 s. A mismatch means no rule or approval matches: ask mode asks, block-all drops, and the log says `address_mismatch`. On TCP port 443 a flow that a rule, the Apple services table or an approval would allow is then held until its TLS ClientHello is read, with a host name from the system as with one from DNS answers (below): the server name must be that host, or a host covered by itself whose address checks out, or the flow is dropped (`server_name_mismatch`). The host name from the system is the app's choice, and the server name picks the site behind a shared address. The hold ends at the hello, within the 10 s that held flows get. In ask mode such a flow is still asked about by its host name before it connects, and an approval resumes it into the hold. |
| Apple services | macOS's own services pass without a rule, through a built-in table (`macos/Sources/BlackiceCore/AppleServices.swift`) of signing identifier → the Apple hosts that service uses. An entry counts only for Apple platform code (no Team ID, `anchor apple`) and only when the address checks out, as for a rule; the log says `apple_service`. The table comes from the first ask-mode run's event log plus well-known services. Tools that run commands or fetch any URL (curl, nscurl, python3, perl, ruby, the shells, ssh, scp, nc, git, osascript, Safari, WebKit's networking process, nsurlsessiond) are never in it, and a test checks that. trustd and ocspd get Apple's hosts and those of the main public certificate authorities, not any host on port 80: a certificate names its own OCSP, CRL and issuer URLs, so any app could reach a host of its choosing through trustd. On by default; `apple_services = false` turns it off. |
| Any destination | `hosts = ["*"]`, alone in a rule, lets that app reach anything, including flows with an address and no host name, in block-all and ask. No host or address check applies, and the log says `rule_line_N`. For VPN clients and DNS proxies, which connect by address, and for a browser you would allow everywhere anyway. Everything the app does is then allowed. `*` next to other hosts is an error. |
| Names from DNS answers | In ask and block-all the extension reads the system resolver's DNS traffic (mDNSResponder's port-53 flows, UDP and TCP) and passes every byte unchanged; accept-all reads nothing. A response counts only when it answers a query sent on the same flow, with the same ID and question, the check the resolver applies itself. The question's name is recorded against the A and AAAA addresses at the end of its CNAME chain (never the CNAME targets), for the records' TTL held between 30 s and 5 minutes, at most 16 names per address and 4096 addresses. Anything malformed, truncated or not understood teaches nothing. A connection with no host name from the system whose address was given for exactly one name is decided on that name, which passes the host and address check since it came with the address: rules and approvals for it count, and ask mode asks about it. On port 443 the TLS server name is still read, and a server name other than that one must be covered itself, or the connection is dropped (`server_name_mismatch`), so an app cannot look up an allowed name and then reach another site on the same CDN address. Several names for one address, or none, leave the server name path as it was. |
| DNS in block-all | Apple's resolver stays reachable on port 53 in every mode, so in block-all any app can still make name lookups through it, which can carry data out. Documented as a known gap; tying DNS answers to rules with an `NEDNSProxyProvider` is later work. |
| Hooks that leave their process group | Best effort, and documented: a process started by a hook that calls `setsid` or `setpgid` escapes the kill at the deadline and when the hook exits. Running hooks under a separate user or in a sandbox would close this; neither is planned yet. |
| Approval storage | In memory, inside the extension. Permanent rules live in `blackice.toml`. |
| Who can approve | The hook, with the event's one-time token, or a person with Touch ID. |
| Daemon | `blackice daemon` takes no options and reads no file (decided on 3 November 2026). The extension's reply to its registration carries the configuration the extension holds, the `blackice.toml` text that `start` or `mode` saved after Touch ID plus its generation, and the daemon takes its hooks and timeout from it, parsed with the same strict parser. Each event carries the generation the extension held when it sent it; a daemon holding another one registers again on the same connection to get the current configuration, and runs no hook for an event whose configuration is gone. Hooks get an environment the daemon builds: `HOME`, `USER` and `LOGNAME` from the user database, `TMPDIR` from confstr, a fixed `PATH` and `LANG`, and the event's file and ID. `blackice agent install` and `uninstall` write and load, or unload and remove, the LaunchAgent, without Touch ID. |
| Configuration | `blackice.toml`, read by a small strict parser for the subset the file uses. No third-party dependency. |
| Apple account | Individual Developer Program membership. |

## Architecture

- **Blackice.app**, with no UI, installed in `/Applications`. It contains the network extension and the
  `blackice` binary. macOS activates system extensions only from an app in `/Applications`.
- **The extension** (`NEFilterDataProvider`) decides right away in accept-all and block-all. In ask mode it pauses
  the flow, sends an event to the daemon over XPC, and resumes the flow when an answer arrives or the timeout passes.
- **`blackice daemon`** runs as a LaunchAgent for the user, receives events and runs the hooks. The extension
  cannot start processes.
- **`blackice approve`** reaches the extension over XPC, adds a temporary rule and releases matching paused flows.

## Phases

0. **Developer ID signing.** Apple Developer Program membership, a Developer ID Application certificate, App IDs
   and Developer ID provisioning profiles with the content filter entitlement. Sign Blackice.app (phase 1's
   skeleton) and activate it on a test Mac. *Done when* a small binary signed with our Team ID is blocked by the
   extension and the rest of the Mac keeps working. The steps, scripts and rollback are in
   [`phase-0.md`](phase-0.md).
   *Done* on 3 November 2026, on a MacBook Air (Mac16,12) with macOS 27.0.1, with `macos/scripts/phase0-test.sh`:
   the probe, signed with our Team ID and named by no rule, connected in accept-all and was refused in
   block-all, and `curl`, with a rule for pypi.org, got HTTP 200 in both modes. The first runs turned up the
   following, which the scripts, the extension and `phase-0.md` now handle:
   - macOS activates a Developer ID system extension only once it is notarized. Before that, activation fails
     with OSSystemExtensionErrorDomain 8, "code signature invalid".
   - A network extension needs `NSSystemExtensionUsageDescription` in its Info.plist (error 9 without it).
   - `::ffff:127.0.0.1/104` is not a valid NEFilterRule prefix (macOS reads the address as IPv4), so saving the
     filter settings failed. Loopback is now `127.0.0.1/8` and `::1/128`.
   - mDNSResponder sends some lookups on behalf of an app, under that app's audit token. The process that sends
     them is in `sourceProcessAuditToken`, which the resolver exemption now checks as well.
   - Replacing a signed app in /Applications needs App Management for the terminal (System Settings → Privacy &
     Security).
   - The first activation, and any activation after a deactivation, waits for approval in System Settings.
1. **Skeleton.** Blackice.app, `blackice start/stop/status/mode`, accept-all and block-all, a JSONL event log, and
   the `blackice.toml` parser with tests. *Done when* `mode block-all` stops a `curl`, `mode accept-all` lets it
   through, and both leave a log line.
   *So far*, without the extension: the Swift package in `macos/` with the `blackice.toml` parser, rule matching,
   the hook event and token, the CLI's argument parsing and `blackice validate`, plus the parts ported from
   blackice-poc (code identity, host names, TLS server name). Unit tests run in CI on macOS.
   Also without the extension: the JSONL event log, and a daemon that logs each event and runs its hooks. A
   LaunchAgent template is in `macos/LaunchAgent/`; `blackice agent install` writes and loads it (run on a Mac in
   P2-02 and P5-01).
   Written and compiled, and run on a Mac since phase 0: Blackice.app, built with SwiftPM and scripts, whose executable
   is the CLI, with the content filter as a system extension. `blackice start/stop/mode` activate and deactivate
   the extension and save the filter preference, each after Touch ID; the CLI saves blackice.toml's text, the mode
   and a generation number in the provider configuration, and the extension reads only that. The extension's
   decision is unit-tested. In every mode inbound connections pass and Apple's resolver may reach port 53, since
   rules name hosts. Without a host name from the system, the extension reads the TLS server name, but only for
   an app that has a rule. It logs one line per decision to unified logging; the JSONL event log is the daemon's
   and holds events, hooks and verdicts.
   *On a Mac*, phase 0's run showed this with the probe in place of `curl`: refused in block-all, with the log
   line `flow drop no_rule`, and let through in accept-all.
2. **Ask mode.** Pausing, XPC, the pending list, deny on timeout, `blackice pending/approve/deny` with `--app`,
   `--host` and `--for`, the event token and Touch ID. A repeated connection (same app, host and port) raises one
   event. *Done when* a `curl` waits, `approve` releases it, and with no answer the timeout drops it.
   *So far*, unit-tested without the extension: approvals in memory with an expiry (1 s to 24 h, at most 1024);
   paused connections with one event per app, host and port and caps on events and flows; the event token, which is
   single use, bound to its event, compared in constant time and dead once the deadline passes; the deadline
   dropping what nobody answered; the host and address check, with a fake resolver; ad hoc code named by its
   cdhash; and the XPC messages, each decoded and checked field by field on receipt. `blackice pending`,
   `approve` and `deny` parse `--app/--team` or `--cdhash`, `--host`, `--for` and `--token`.
   Written and compiled, then run on a Mac (below): the extension pausing flows while their host is looked up and
   while their event waits, then resuming them on an answer or at the deadline; an XPC listener in the extension
   that the CLI and the daemon reach, with each side's code signing requirement (same team, exact signing
   identifier) set on the connection so it is checked on every message; Touch ID for `approve` and `deny` without
   a token; and `blackice daemon` registering with the extension for events, then exiting with status 75 when
   the connection ends so launchd starts it again.
   *On a Mac*, 3 November 2026, with fx deciding through the hook (phase 4): `nscurl https://api.github.com/zen`
   waited, fx approved it with the event's token, and it got HTTP 200 after 18 s; `nscurl https://pastebin.com/`
   waited until fx denied it, 16 s in; and `example.org`, which the demo's hook left alone, was dropped at the
   60 s deadline. A mode change cancels the events still waiting. The same run with `curl` failed even when
   approved: see "Connections named by their TLS server name" under the open problems.
   *On a Mac* with build 4, the same day, after names from DNS answers and `hold_expired` were added
   ([P2-02](../evidence/P2-02-curl-passes-on-retry-nscurl-waits-macos.md)): `curl https://api.github.com/zen` waited
   with its TCP connection already ESTABLISHED, and its first try failed after 16 s; fx approved meanwhile, and the
   retry got HTTP 200 at once. `nscurl https://registry.npmjs.org/` waited 28 s for fx and got HTTP 200. fx denied
   `curl https://pastebin.com/` for each of its two addresses.
   *Done* for apps that connect by name: a connection waits, an approval releases it (P2-01, P2-02) and with no
   answer the deadline drops it (P2-01, and cases 1 and 2 of P5-01). For `curl`, and other tools that connect to an
   address, only the retry after an approval gets through; the first try fails when the decision takes longer than
   the server waits for the TLS hello.
3. **Hooks.** `run = '…'` in `blackice.toml`, the event as JSON on stdin plus its token, and a limit on hooks
   running at once. *Done when* a sample hook approves one host and denies another.
   *So far*, tested without the extension: the hook runner. It runs `run` with `/bin/sh -c` and never puts event
   data in the command line. The event goes on stdin and in a 0600 file inside a private 0700 directory, named in
   `BLACKICE_EVENT_FILE`. The hook runs in that directory, which is deleted afterwards. Hooks get a short, explicit
   environment without the token. At the deadline the hook's process group gets SIGTERM, then SIGKILL after a grace
   period, and anything a hook leaves in its group is killed when it exits. At most 4 hooks run at once. Until
   4 November 2026 a hook with no free slot was not started and was logged as dropped; since then it waits for one
   (see "Hooks in a burst" under the open problems).
   *On a Mac*, the daemon registered with the extension, received each event and ran the hook. fx prints the
   commands it runs, token included, and the first run copied them into the event log with the hook's stderr;
   the runner now replaces the token, and any piece of it of 8 characters or more, with `[token]`. With build 4
   (P2-02) the daemon took its hooks from the extension's configuration, and each hook record's stderr held
   `[token]` where fx had printed the token. The fault tests (P5-01) showed a hung hook killed at the deadline and,
   in a burst, at most 4 hooks at once with the rest logged as dropped (before the queue).
   *Done* on 3 November 2026: on a Mac the hook, running fx, approved api.github.com and denied pastebin.com
   (P2-01, P2-02).
4. **The agent decides.** An fx skill that says what to look at, when to approve and how to call `approve`. A fixed
   allow rule for the deciding agent and its model provider, bound to their signatures. *Done when* fx decides ten
   test connections with nobody touching the keyboard.
   *So far*, without the extension: the fx skill and an eval that runs fx on fixed events the way the hook would,
   with `blackice` replaced by a stub. On 2 November 2026, fx 0.0.16 decided ten of ten in four runs, two of them
   with rules that let it run only `blackice approve` and `blackice deny` (see `integrations/fx/README.md`).
   *On a Mac*, 3 November 2026, fx 0.0.16 ran with those rules and a fixed allow rule for itself (`com.vercel.fx`,
   team JW6Y669B67, to ai-gateway.vercel.sh, vercel.com and api.vercel.com). With nobody at the keyboard it
   approved api.github.com for `curl` and `nscurl`, denied pastebin.com each time, and approved a Homebrew `gh`
   (ad hoc signed, named by its cdhash) reaching api.github.com. Each decision took 13 to 22 s.
   *Done* the same day: in one run, fx decided ten `nscurl` connections in a row with nobody at the keyboard. It
   approved api.github.com, registry.npmjs.org, formulae.brew.sh and developer.apple.com, each of which then got
   HTTP 200, and denied pastebin.com, wetransfer.com, webhook.site, 0x0.st and a random nip.io name. It also
   denied pypi.org, which it was expected to approve. It printed only the command it ran, not its reasons, and it
   approved npm and Homebrew for the same `nscurl`, so the skill's guidance on package registries needs a look.
   Decisions took 11 to 28 s.
   In 0.3.0, `blackice agent connect fx` sets this up in one command (the skill and rules in fx's own home, a test on
   a sample event, the rule, the hook and the timeout), and the first `blackice start` does it when the person picks
   fx. A trial build did it on the Mac, and fx then answered real connections in ask mode
   ([P5-05](../evidence/P5-05-agent-connect-fx-macos.md)). From no blackice and no fx, 0.3.0 candidates installed fx
   and signed it in from `start`; the run went on with an earlier sign-in, because the new one's Vercel team had no
   card for AI Gateway, and fx approved two connections in about 5 s
   ([P5-06](../evidence/P5-06-onboarding-from-zero-macos.md)).
5. **Hardening and evidence.** Fault tests (daemon down, hook hung, bursts of connections, restart), evidence
   entries in the style of blackice-poc, notarization and an installer. *Done when* `macos/scripts/fault-test.sh`
   passes on a Mac and the run is recorded in [`evidence/`](../evidence/), and a `Blackice-<version>.zip` from
   `macos/scripts/package.sh` passes the script's checks (checksum, signature, stapled ticket, Gatekeeper) and
   installs, runs and uninstalls on a Mac by following [`install.md`](install.md).
   *So far*: [`evidence/`](../evidence/) records the runs so far, each from its logs: phase 0's check (P0-01), the
   ask-mode runs with fx (P2-01, P2-02), the ten connections fx decided (P4-01) and the fault tests (P5-01).
   `macos/scripts/fault-test.sh` covers the four faults with one test configuration and two Touch ID prompts: with
   no daemon registered, a paused connection's event is not sent (`control event_not_sent no_daemon`) and the
   deadline drops it; a hook that sleeps past the deadline is killed (`hook_killed`, reason `deadline`) and its
   connection dropped (`timed_out`); a burst of 50 connections to distinct hosts and 70 to one host shows one event
   per app, host and port, at most 64 connections per event (`flow drop ask_capacity` beyond), at most 4 hooks at
   once with the rest waiting for a slot (`hook_queued`, then `hook_started` with `waited_ms`, or `hook_dropped`
   with `deadline_near` once too little time is left), and `curl` with a rule still working; and after
   the daemon is killed, launchd starts it and it registers again (`control xpc daemon_registered`), then a
   configuration change while connections wait drops them (`configuration_changed`) and cancels their events.
   *On a Mac*, 3 November 2026, with build 4 ([P5-01](../evidence/P5-01-faults-macos.md)): 24 checks passed and 4
   failed. Daemon down, hook hung, the burst and the restart passed; after `launchctl kill`, the daemon was running
   and registered again within 1 s. The last four checks, the configuration change, failed. The second Touch ID was
   cancelled, so the change did not happen, and `blackice pending` rejected the extension's reply ("events has an
   invalid entry"; see "Events with no connection left" under the open problems). The build 4 run just before
   (P2-02) shows that change outside the script: at the switch to accept-all, 21 paused flows were dropped with
   `configuration_changed` and their five events were cancelled.
   Notarization has run in `sign.sh` since phase 0; builds 2, 3 and 4 were notarized and stapled.
   `macos/scripts/package.sh` zips the notarized, stapled app with a SHA-256 file and checks both as a download; it
   built and checked the v0.1.0 release's zip (P5-02). A `.pkg` would need a Developer ID Installer
   certificate, which the account does not have, so the installer is the zip and `install.md`. The same zip is
   offered through a Homebrew cask (`valentintorassa/tap`), and `packaging/npm/` holds an npm package that downloads
   and checks it, not published. On 3 November 2026 the cask installed 0.1.0 from the published release over build 4
   ([P5-02](../evidence/P5-02-homebrew-upgrade-from-release-macos.md)): the app verified as signed, notarized and
   accepted, `blackice start` found the upgraded extension unreachable and exited with 75, and after a restart it
   answered. Build 4 replaces the token in the hooks' stderr (P2-02), which the builds of the earlier fx runs did
   not.
   *Done* on 3 November 2026, with the published 0.2.1 ([P5-04](../evidence/P5-04-install-start-faults-from-release-macos.md)): the uninstall steps of
   `install.md` removed the previous install, the curl one-liner checked the release and installed it into
   `/Applications`, the first `blackice start` turned blackice on, and the fault tests passed all 28 checks, the
   configuration change included. The System Settings steps that 0.2.1 prints for macOS 14 and 15 have not run.
   With 0.3.0 candidates the uninstall steps, the one-liner and the first `start` ran again, from no configuration
   and no fx, and three failures on the way were fixed before build 11
   ([P5-06](../evidence/P5-06-onboarding-from-zero-macos.md)). Build 11 dropped Apple's developer tools (git over
   HTTPS, `notarytool`) and Mac App Store apps as `invalid_signature` in ask mode; build 13 asks about them
   ([P5-07](../evidence/P5-07-apple-tools-invalid-signature-macos.md)).

## Open problems

- **Hooks in a burst.** The daemon runs at most 4 hooks at once. Until 4 November 2026 it had no queue: an event
  that arrived while 4 ran was logged as `hook_dropped` (`concurrency_limit`) and waited for its deadline. fx answers
  in about 16 s, so one app that opens many connections at once crowded out the rest. On the Mac after the
  recorded onboarding, a VPN client's network extension sent 53 of 94 events in ten minutes, mostly in two bursts;
  62 events got no hook and 31 connections were dropped at the deadline
  ([P5-08](../evidence/P5-08-onboarding-published-0.3.0-recorded-macos.md)).
  Twenty minutes later, building 0.3.1 in ask mode failed the same way: `codesign`'s request to Apple's timestamp
  service (`com.apple.security.XPCTimeStampingService` to timestamp.apple.com) arrived while 4 hooks ran, got no
  hook, and the signature had no timestamp.
  The Mac's event log from 3 November 04:23 to 4 November 08:48 UTC holds 905 events and 351 `hook_dropped`. The VPN
  client was Tailscale's network extension (`io.tailscale.ipn.macsys.network-extension`, its DERP relays): 316 of
  the events and 227 of the drops. 94 drops were the fault test's burst, on purpose, and 30 came from other apps.
  Replaying the log with 4 hooks of 16 s each, the events other than Tailscale's, the Apple services above and the
  tests lose 35 without a queue and none with one.
  Done since: the first start's list shows the running system extensions, so a VPN client's can be trusted there,
  and the timestamp service and three other services seen in the log are in the Apple services table. And the
  daemon has a queue: a hook that finds 4 running waits for a slot without holding a thread (`hook_queued`, then
  `hook_started` with `waited_ms`). Waiting hooks take turns between apps (by signing identity, or cdhash), oldest
  first within an app, so one app's burst no longer crowds out the rest. A waiting hook is dropped once less than
  10 s of its time is left (`deadline_near`), when the extension reports its event's end while it waits
  (`event_ended`), and when 256 hooks already wait (`queue_full`). On the Mac with build 15, the fault test's burst
  ran at most 4 hooks, 46 waited, those that got a slot in time started after up to 15.7 s and the rest were given
  up as `deadline_near`, and the Mac kept working ([P5-09](../evidence/P5-09-hook-queue-faults-0.3.2-candidate-macos.md)).
  One hook for several events
  of the same app stays a candidate for bursts a queue cannot absorb: at 16 s per decision 4 slots answer about 15
  events a minute.
- **Deadlock.** The deciding agent needs the network to reach its model. If that connection also goes to ask mode,
  it waits for its own approval. Phase 4's fixed rule for the decider handles this; it has to exist before ask mode
  is turned on for real.
- **Self-approval.** Any program of the user can run `blackice approve`. Requiring the event's token keeps a
  program from approving its own connection.
- **Daemon impersonation.** Any program of the user can still run `blackice daemon` and register in place of the
  LaunchAgent, but that copy runs the hooks of the configuration saved with Touch ID, in an environment it builds
  itself (see Daemon under the decisions), so it cannot run hooks of its own. What remains: such a program can keep
  the LaunchAgent's daemon from getting events, by registering again and again or by stopping it, and connections
  then wait and are denied at their timeout. And the programs a hook runs read files that any program of the user
  can change, such as fx's rules and skill in the agent's home.
- **Prompt injection.** Host names, app names and TLS server names are chosen by whoever opens the connection, and
  they reach the model's prompt. Events carry them as structured fields, and the only accepted answers are approve
  or deny.
- **Latency and volume.** A model takes seconds and a Mac opens hundreds of connections. Rules, expiring approvals
  and one event per repeated connection keep the questions to new destinations.
- **Connections named by their TLS server name.** An app that connects to an address (`curl` and most
  command-line tools) gives the filter no host name. On 3 November 2026 blackice read it from the TLS hello,
  after the TCP connection was up, and held the hello while the event waited; servers close a connection that
  sends no hello (GitHub after 11 s, Cloudflare after 15 s), and fx took 13 to 22 s, so the `curl` it approved
  had already lost its connection. Since then, such a connection is named from the resolver's DNS answers when
  its address was given for one name (see "Names from DNS answers" above), and in ask mode a paused connection
  that the server already sees as connected is dropped after 8 s (`hold_expired`) while its event stays open until
  the deadline, so an approval covers the app's next try. With build 4
  ([P2-02](../evidence/P2-02-curl-passes-on-retry-nscurl-waits-macos.md)), `curl` to api.github.com raised an
  event named api.github.com, fx approved it, and the retry got HTTP 200 at once. What remains:
  - The first connection still fails when the decision takes longer than the server waits, and only a retry gets
    through (`curl` retries only with `--retry`). XNU's published source sends the SYN at `connect()` and only
    keeps the app from seeing the connection until the first verdict, so a pause at the new-flow stage leaves
    the server waiting too. P2-02 confirms it: during the pause, `netstat` showed the connection ESTABLISHED.
  - In P2-02 the first try was not dropped at 8 s as `hold_expired` intends. It failed at 16 s, when fx's approval
    arrived and the filter let one paused flow through, which by the times was curl's. Why the 8 s hold did not
    apply to it is not established.
  - A name the resolver answered from its own cache is never seen on the wire, so that connection takes the
    server name path. And when two names share an address but only one was seen, the event can name the other
    one; the server name check then drops the connection rather than let it through.
  - Apps that connect by name (URLSession, Network.framework) carry the host name and are asked about at once:
    `nscurl` waited 18 s (P2-01) and 28 s (P2-02) for fx's approval and got HTTP 200. Since 4 November 2026 such a
    connection on port 443, once a rule or an approval allows it, is held until its ClientHello is read (see "Host
    and address"). Not yet run on a Mac.
- **The Mac's own services in ask mode.** With only the demo's rules, iCloud, CalDAV, Software Update, Maps and
  AuthKit were paused and then dropped at the deadline, and the demo's three events were a few among dozens. The
  Apple services table (see the decisions) now covers those and other well-known services. In the build 4 run
  (P2-02) 13 flows passed as `apple_service`, and still asked about were nsurlsessiond (kept out of the table on
  purpose), tipsd (added to the table since), a Google calendar synced by dataaccessd (which needs a rule), and
  cloudd reaching gateway.icloud.com, which the table covers but whose address check failed. A service or host
  missing from the table is still asked about. A service's UDP flow with no host name is still dropped
  (`no_host`), and Apple's CDN answers can fail the address check. The mode also stays on until someone
  switches it with Touch ID: when the demo's window closed early, the Mac kept pausing every new connection.
- **VPN and DNS proxies.** With Tailscale's DNS on, the system's lookups go to 100.100.100.100 through Tailscale's
  extension, which forwards them with its own sockets by address: flows with no host name, which blackice drops
  (`no_host`), so names stop resolving in ask and block-all. The demo ran with `tailscale set --accept-dns=false`.
  A rule with `hosts = ["*"]` for the extension now allows those flows; the docs use the standalone build's
  identity, read with `codesign -dv` on the test Mac (`io.tailscale.ipn.macsys.network-extension`, team
  W5364U7YZB). It has not been seen at work on a Mac yet: in P2-02 the rule was loaded but allowed nothing. What
  remains: blackice ships no such rule, so each VPN client or DNS
  proxy needs one from the user, and the rule allows everything that extension does.
- **A denial is not remembered.** After a deny, the app's next try (`curl` moving on to another address) raises a
  new event, and the agent is asked again.
- **Touch ID count.** `start`, `stop` and `mode` each ask for Touch ID, so a demo takes two. A short unlock
  window, like sudo's, is a candidate. A test that needs a person at the keyboard can also fail for that reason:
  the fault test's second Touch ID was cancelled, and the check that depends on it failed (P5-01).
- **Upgrades in place.** On 3 November 2026, on macOS 27.0.1, build 4 put in `/Applications` over build 3 and
  activated with `blackice start` replaced the running extension, which kept filtering but had no Mach service:
  `launchctl print` showed it with no endpoints, and lookups of its XPC service failed with "No such process". The
  daemon, `pending`, `approve` and `deny` could not reach it, so ask mode dropped everything it paused at the
  deadline. A restart fixed it; P2-02 is the same build after the restart. `blackice start` now checks, after macOS
  replaces a running extension, that its XPC service answers, and if it does not, says to restart and exits with
  status 75. [`install.md`](install.md)'s upgrade steps include the restart. The upgrade from build 4 to build 5
  with Homebrew did the same, and the check caught it ([P5-02](../evidence/P5-02-homebrew-upgrade-from-release-macos.md)):
  two upgrades out of two. Why is not known; for now an upgrade means a restart. The upgrade to build 15 answered
  at once, but the build 14 it replaced had been activated over build 13 that morning and had never been reachable,
  with no restart in between ([P5-09](../evidence/P5-09-hook-queue-faults-0.3.2-candidate-macos.md)).
- **Events with no connection left.** In P5-01, `blackice pending` failed with "the network extension sent an
  invalid reply: events has an invalid entry": an event whose paused flows were all dropped with `hold_expired`
  stays pending, by design, and is listed with 0 connections, while the CLI's check of the reply required at
  least 1. Fixed after that run: the check takes 0, and `pending` shows "no connection left (an approval covers
  the next try)" (`CLITests`). Not yet run on a Mac.
- **Limits of the host check.** The system resolver may answer blackice's lookup differently than it answered
  the app (round-robin, CDNs, split DNS), which shows as a mismatch: ask mode asks and block-all drops. And a match
  proves only that the name resolves to that address now, not who controls the name. The server name is read only
  from TCP on port 443: on another port, over UDP (QUIC) or in the HTTP `Host` header, an app with a rule for one
  host can still name another site behind the same address.
- **Hook limits.** The limit of 4 hooks at once, at most 256 hooks waiting for a slot, the 10 s a waiting hook needs
  left to start (or the whole timeout, when that is shorter), the 2 s grace period and the 4 KiB of stderr kept per
  hook are first guesses, set in code rather than in `blackice.toml`.
- **Log rotation.** The event log only grows. Rotation, or leaving it to newsyslog, is not decided.
- **Installation.** No dialog per connection, but macOS asks once to allow the extension in System Settings, unless
  the Mac is managed with an MDM profile.
