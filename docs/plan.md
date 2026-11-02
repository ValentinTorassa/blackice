# Plan

netshield is in planning. This file holds the phases, the decisions taken so far and the open problems. A phase is
done when its check passes on a real Mac, not when the code compiles.

## Decisions

| Topic | Decision |
|---|---|
| Repository | Its own repo. Swift files come from blackice's macOS app filter, with the source commit noted in each file. |
| Language | Swift for the extension, the CLI and the daemon. |
| Ask mode | Asks only about connections that no rule or current approval covers. |
| No answer in time | Deny after N seconds. N is configurable; its default is set after measuring how long macOS keeps a paused flow. |
| Approval scope | One app (by signing identity) and one host, with an expiry: `netshield approve --app … --host … --for 1h`. |
| Approval storage | In memory, inside the extension. Permanent rules live in `netshield.toml`. |
| Who can approve | The hook, with the event's one-time token, or a person with Touch ID. |
| Configuration | `netshield.toml`, read by a small strict parser for the subset the file uses. No third-party dependency. |
| Apple account | Individual Developer Program membership. |

## Architecture

- **Netshield.app**, with no UI, installed in `/Applications`. It contains the network extension and the
  `netshield` binary. macOS activates system extensions only from an app in `/Applications`.
- **The extension** (`NEFilterDataProvider`) decides right away in accept-all and block-all. In ask mode it pauses
  the flow, sends an event to the daemon over XPC, and resumes the flow when an answer arrives or the timeout passes.
- **`netshield daemon`** runs as a LaunchAgent for the user, receives events and runs the hooks. The extension
  cannot start processes.
- **`netshield approve`** reaches the extension over XPC, adds a temporary rule and releases matching paused flows.

## Phases

0. **Developer ID signing.** Apple Developer Program membership, a Developer ID Application certificate, App IDs
   and Developer ID provisioning profiles with the content filter entitlement. Sign Netshield.app (phase 1's
   skeleton) and activate it on a test Mac. *Done when* a small binary signed with our Team ID is blocked by the
   extension and the rest of the Mac keeps working. The steps, scripts and rollback are in
   [`phase-0.md`](phase-0.md).
1. **Skeleton.** Netshield.app, `netshield start/stop/status/mode`, accept-all and block-all, a JSONL event log, and
   the `netshield.toml` parser with tests. *Done when* `mode block-all` stops a `curl`, `mode accept-all` lets it
   through, and both leave a log line.
   *So far*, without the extension: the Swift package in `macos/` with the `netshield.toml` parser, rule matching,
   the hook event and token, the CLI's argument parsing and `netshield validate`, plus the parts ported from
   blackice (code identity, host names, TLS server name). Unit tests run in CI on macOS.
   Also without the extension: the JSONL event log, and a daemon skeleton that logs each event and runs its hooks.
   Its intake from the extension is only a protocol until phase 2, so `netshield daemon` checks its configuration and
   exits with status 69. A LaunchAgent template is in `macos/LaunchAgent/`; nothing installs it.
   Written and compiled, not run until phase 0: Netshield.app, built with SwiftPM and scripts, whose executable
   is the CLI, with the content filter as a system extension. `netshield start/stop/mode` activate and deactivate
   the extension and save the filter preference, each after Touch ID; the CLI saves netshield.toml's text, the mode
   and a generation number in the provider configuration, and the extension reads only that. The extension's
   decision is unit-tested. In every mode inbound connections pass and Apple's resolver may reach port 53, since
   rules name hosts. Without a host name from the system, the extension reads the TLS server name, but only for
   an app that has a rule. It logs one line per decision to unified logging; the JSONL event log is not wired to
   it yet.
2. **Ask mode.** Pausing, XPC, the pending list, deny on timeout, `netshield pending/approve/deny` with `--app`,
   `--host` and `--for`, the event token and Touch ID. A repeated connection (same app, host and port) raises one
   event. *Done when* a `curl` waits, `approve` releases it, and with no answer the timeout drops it.
3. **Hooks.** `run = '…'` in `netshield.toml`, the event as JSON on stdin plus its token, and a limit on hooks
   running at once. *Done when* a sample hook approves one host and denies another.
   *So far*, tested without the extension: the hook runner. It runs `run` with `/bin/sh -c` and never puts event
   data in the command line. The event goes on stdin and in a 0600 file inside a private 0700 directory, named in
   `NETSHIELD_EVENT_FILE`. The hook runs in that directory, which is deleted afterwards. Hooks get a short, explicit
   environment without the token. At the deadline the hook's process group gets SIGTERM, then SIGKILL after a grace
   period, and anything a hook leaves in its group is killed when it exits. At most 4 hooks run at once; a hook with
   no free slot is not started, is logged as dropped, and the connection is denied when its timeout passes.
4. **The agent decides.** An fx skill that says what to look at, when to approve and how to call `approve`. A fixed
   allow rule for the deciding agent and its model provider, bound to their signatures. *Done when* fx decides ten
   test connections with nobody touching the keyboard.
5. **Hardening and evidence.** Fault tests (daemon down, hook hung, bursts of connections, restart), evidence
   entries in the style of blackice, notarization and an installer.

## Open problems

- **Deadlock.** The deciding agent needs the network to reach its model. If that connection also goes to ask mode,
  it waits for its own approval. Phase 4's fixed rule for the decider handles this; it has to exist before ask mode
  is turned on for real.
- **Self-approval.** Any program of the user can run `netshield approve`. Requiring the event's token keeps a
  program from approving its own connection.
- **Prompt injection.** Host names, app names and TLS server names are chosen by whoever opens the connection, and
  they reach the model's prompt. Events carry them as structured fields, and the only accepted answers are approve
  or deny.
- **Latency and volume.** A model takes seconds and a Mac opens hundreds of connections. Rules, expiring approvals
  and one event per repeated connection keep the questions to new destinations.
- **Paused flow lifetime.** How long macOS keeps a paused flow before dropping it is not measured yet. It sets the
  upper bound for the timeout.
- **Host names are taken as given.** Rules match the host name macOS attaches to a flow, or the TLS server name
  the app sends. Neither is checked against the address the app connects to, so an app with a rule for one host
  could name that host and connect elsewhere. Checking them is phase 5 work.
- **DNS in block-all.** Apple's resolver may reach port 53 in every mode, so in block-all any app can still make
  name lookups through it, which can carry data out. Closing this needs DNS answers to be tied to rules.
- **Unsigned code.** Connections from unsigned or ad hoc signed code have no signing identity, so an approval
  cannot name them. What ask mode does with them is open.
- **Event delivery to an agent.** Hooks get the event as JSON on stdin, but `fx ask` reads stdin as its prompt only
  when no prompt arguments are given. The hook runner also writes the event to a file named in
  `NETSHIELD_EVENT_FILE`, which is what the fx skill reads (see `integrations/fx/README.md`). Not yet tried with fx.
- **Hooks that leave their process group.** A process started by a hook that calls `setsid` or `setpgid` escapes
  the kill at the deadline and when the hook exits. Running hooks under a separate user or in a sandbox would close
  this; neither is planned yet.
- **Hook limits.** The limit of 4 hooks at once, the 2 s grace period and the 4 KiB of stderr kept per hook are
  first guesses, set in code rather than in `netshield.toml`.
- **Log rotation.** The event log only grows. Rotation, or leaving it to newsyslog, is not decided.
- **Installation.** No dialog per connection, but macOS asks once to allow the extension in System Settings, unless
  the Mac is managed with an MDM profile.
- **Name.** Proton VPN uses NetShield for its ad and malware blocker. The name stays for now.
