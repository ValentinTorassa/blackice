# Plan

blackice is in planning. This file holds the phases, the decisions taken so far and the open problems. A phase is
done when its check passes on a real Mac, not when the code compiles.

## Decisions

| Topic | Decision |
|---|---|
| Name | The product ships as blackice (decided on 2 November 2026 with Esteban). netshield was the working name until then. The first proof of concept, also called blackice, is archived as [ValentinTorassa/blackice-poc](https://github.com/ValentinTorassa/blackice-poc). |
| Repository | Its own repo. Swift files come from blackice-poc's macOS app filter, with the source commit noted in each file. |
| Language | Swift for the extension, the CLI and the daemon. |
| Ask mode | Asks only about connections that no rule or current approval covers. |
| No answer in time | Deny after N seconds. N is configurable. macOS keeps a paused TCP flow as long as we want, so what bounds N is how long the app and the server wait (see the open problems). |
| Approval scope | One app (by signing identity) and one host, with an expiry: `blackice approve --app … --host … --for 1h`. |
| Ad hoc signed code | Ask mode asks about it too, and the approval names its cdhash plus the host: `blackice approve --cdhash … --host …`. A rebuild changes the cdhash, so the next connection asks again. Rules in `blackice.toml` never name it, so block-all drops it. Code with no signature has no cdhash either and is dropped. |
| Host and address | Before a rule or an approval counts, the host is resolved with the system resolver and the flow's remote address must be among the answers, which are kept for 30 s. A mismatch means no rule or approval matches: ask mode asks, block-all drops, and the log says `address_mismatch`. |
| DNS in block-all | Apple's resolver stays reachable on port 53 in every mode, so in block-all any app can still make name lookups through it, which can carry data out. Documented as a known gap; tying DNS answers to rules with an `NEDNSProxyProvider` is later work. |
| Hooks that leave their process group | Best effort, and documented: a process started by a hook that calls `setsid` or `setpgid` escapes the kill at the deadline and when the hook exits. Running hooks under a separate user or in a sandbox would close this; neither is planned yet. |
| Approval storage | In memory, inside the extension. Permanent rules live in `blackice.toml`. |
| Who can approve | The hook, with the event's one-time token, or a person with Touch ID. |
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
   LaunchAgent template is in `macos/LaunchAgent/`; nothing installs it.
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
3. **Hooks.** `run = '…'` in `blackice.toml`, the event as JSON on stdin plus its token, and a limit on hooks
   running at once. *Done when* a sample hook approves one host and denies another.
   *So far*, tested without the extension: the hook runner. It runs `run` with `/bin/sh -c` and never puts event
   data in the command line. The event goes on stdin and in a 0600 file inside a private 0700 directory, named in
   `BLACKICE_EVENT_FILE`. The hook runs in that directory, which is deleted afterwards. Hooks get a short, explicit
   environment without the token. At the deadline the hook's process group gets SIGTERM, then SIGKILL after a grace
   period, and anything a hook leaves in its group is killed when it exits. At most 4 hooks run at once; a hook with
   no free slot is not started, is logged as dropped, and the connection is denied when its timeout passes.
   *On a Mac*, the daemon registered with the extension, received each event and ran the hook. fx prints the
   commands it runs, token included, and the first run copied them into the event log with the hook's stderr;
   the runner now replaces the token, and any piece of it of 8 characters or more, with `[token]`.
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
5. **Hardening and evidence.** Fault tests (daemon down, hook hung, bursts of connections, restart), evidence
   entries in the style of blackice-poc, notarization and an installer. *Done when* `macos/scripts/fault-test.sh`
   passes on a Mac and the run is recorded in [`evidence/`](../evidence/), and a `Blackice-<version>.zip` from
   `macos/scripts/package.sh` passes the script's checks (checksum, signature, stapled ticket, Gatekeeper) and
   installs, runs and uninstalls on a Mac by following [`install.md`](install.md).
   *So far*: [`evidence/`](../evidence/) records the runs so far, each from its logs: phase 0's check (P0-01), the
   first ask-mode run with fx (P2-01) and the ten connections fx decided (P4-01). `macos/scripts/fault-test.sh`
   covers the four faults with one test configuration and two Touch ID prompts: with no daemon registered, a
   paused connection's event is not sent (`control event_not_sent no_daemon`) and the deadline drops it; a hook
   that sleeps past the deadline is killed (`hook_killed`, reason `deadline`) and its connection dropped
   (`timed_out`); a burst of 50 connections to distinct hosts and 70 to one host shows one event per app, host and
   port, at most 64 connections per event (`flow drop ask_capacity` beyond), at most 4 hooks at once with the rest
   logged as `hook_dropped` (`concurrency_limit`), and `curl` with a rule still working; and after the daemon is
   killed, launchd starts it and it registers again (`control xpc daemon_registered`), then a configuration change
   while connections wait drops them (`configuration_changed`) and cancels their events. The script has run only
   with `DRY=1`, which validates its configuration and test hook and runs its checks on sample logs; it stops and
   starts the daemon with `blackice agent install|uninstall`, which is not merged yet. Notarization has run in
   `sign.sh` since phase 0. `macos/scripts/package.sh` zips the notarized, stapled app with a SHA-256 file and checks
   both as a download; only its dry run, on an ad hoc signed app, has run. A `.pkg` would need a Developer ID
   Installer certificate, which the account does not have, so the installer is the zip and `install.md`. In both fx
   runs the installed build still copied the tokens fx printed into the event log (spent, and kept out of the
   entries); the build installed for the fault tests should be one with the redaction.

## Open problems

- **Deadlock.** The deciding agent needs the network to reach its model. If that connection also goes to ask mode,
  it waits for its own approval. Phase 4's fixed rule for the decider handles this; it has to exist before ask mode
  is turned on for real.
- **Self-approval.** Any program of the user can run `blackice approve`. Requiring the event's token keeps a
  program from approving its own connection.
- **Daemon impersonation.** Any program of the user can also run `blackice daemon` and register with the
  extension in place of the LaunchAgent. A later registration replaces the earlier one, so that program would get
  the events, tokens included, and could approve its own connection. Candidates: accept only a daemon started by
  launchd, confirm a registration with Touch ID once per login, and have the daemon take its hooks from the
  configuration the extension holds rather than from `--config`.
- **Prompt injection.** Host names, app names and TLS server names are chosen by whoever opens the connection, and
  they reach the model's prompt. Events carry them as structured fields, and the only accepted answers are approve
  or deny.
- **Latency and volume.** A model takes seconds and a Mac opens hundreds of connections. Rules, expiring approvals
  and one event per repeated connection keep the questions to new destinations.
- **Connections named by their TLS server name.** The SDK says macOS keeps a paused TCP flow until the provider
  resumes it (a UDP flow, 10 s). But an app that connects to an address (`curl` and most command-line tools)
  gives the filter no host name, so blackice reads it from the TLS hello, after the TCP connection is up, and
  holds the hello while the event waits. Servers close a connection that sends no hello: GitHub after 11 s,
  Cloudflare after 15 s (measured on 3 November 2026). fx took 13 to 22 s, so the `curl` it approved had already
  lost its connection, and only a retry would have used the approval. Apps that connect by name (URLSession,
  Network.framework) are paused before the TCP connection and can wait the whole timeout. Candidates: learn
  names from the system resolver's answers, so the pause comes before the connection; or drop such a flow after
  a few seconds while its event stays open, so the approval covers the retry.
- **The Mac's own services in ask mode.** With only the demo's rules, iCloud, CalDAV, Software Update, Maps and
  AuthKit were paused and then dropped at the deadline, and the demo's three events were a few among dozens. Ask mode needs rules, or a default, for Apple's own services before it is used for real. The mode
  also stays on until someone switches it with Touch ID: when the demo's window closed early, the Mac kept
  pausing every new connection.
- **VPN and DNS proxies.** With Tailscale's DNS on, the system's lookups go to 100.100.100.100 through Tailscale's
  extension: a flow with an address and no host name, which blackice drops (`no_host`), so names stop resolving
  in ask and block-all. The demo ran with `tailscale set --accept-dns=false`.
- **A denial is not remembered.** After a deny, the app's next try (`curl` moving on to another address) raises a
  new event, and the agent is asked again.
- **Touch ID count.** `start`, `stop` and `mode` each ask for Touch ID, so a demo takes two. A short unlock
  window, like sudo's, is a candidate.
- **Limits of the host check.** The system resolver may answer blackice's lookup differently than it answered
  the app (round-robin, CDNs, split DNS), which shows as a mismatch: ask mode asks and block-all drops. And a match
  proves only that the name resolves to that address now, not who controls the name.
- **Hook limits.** The limit of 4 hooks at once, the 2 s grace period and the 4 KiB of stderr kept per hook are
  first guesses, set in code rather than in `blackice.toml`.
- **Log rotation.** The event log only grows. Rotation, or leaving it to newsyslog, is not decided.
- **Installation.** No dialog per connection, but macOS asks once to allow the extension in System Settings, unless
  the Mac is managed with an MDM profile.
