# Plan

blackice is early: 0.4.2 is its current release ([`CHANGELOG.md`](../CHANGELOG.md)), and it has run on one Mac. This file holds the phases, the decisions
taken so far and the open problems. A phase is done when its check passes on a real Mac, not when the code compiles,
and each run on a Mac is recorded in [`evidence/`](../evidence/).

## Decisions

| Topic | Decision |
|---|---|
| Name | The product ships as blackice (decided on 2 November 2026). The first proof of concept, also called blackice, is archived as [ValentinTorassa/blackice-poc](https://github.com/ValentinTorassa/blackice-poc). |
| Repository | Its own repo. Swift files come from blackice-poc's macOS app filter, with the source commit noted in each file. |
| Language | Swift for the extension, the CLI and the daemon. |
| Ask mode | Asks only about connections that no rule or current approval covers. |
| Dry run of ask mode | In accept-all the extension still allows each new flow at once, with no hold, lookup, event or data read, and its log line adds what ask mode would decide then with the same rules (`would=rule_line_3`, `would=apple_service`, `would=ask`, `would=read_server_name`, `would=drop:no_host`), from the same `FilterPolicy.decide` on the configuration seen in ask mode (decided on 5 November 2026). What accept-all does not know is assumed: every address matches its host, no approval or denial counts, and no DNS answer is read, so a connection with no host name from the system is judged by its address. On port 443 a host the app named that a rule or the table covers is judged as if the hello named it (`rule_line_3;server_name`). `blackice report [--last 1h]` sums the log up with `log show`: drops by reason and app, connections paused to ask by app, and the dry run by app. |
| No answer in time | Deny after N seconds. N is configurable. macOS keeps a paused TCP flow as long as we want, so what bounds N is how long the app and the server wait (see the open problems). |
| Approval scope | One app (by signing identity) and one host, with an expiry: `blackice approve --app … --host … --for 1h`. The host may be an IP address, for a connection with no name (see "Connections by address"). |
| Remembered denials | A deny, from a hook, `blackice deny` or the menu, is remembered for 10 minutes for its app and host, any port (decided on 5 November 2026). In ask mode their new connections are then dropped at once as `denied;remembered`, with no lookup, no event and no hook, where they would have been asked about; a rule still allows what it names. A timeout or a hook with no answer is not remembered. An approval of the pair replaces the denial, a deny of an approved pair replaces the approval, and a configuration change or a stop forgets them all. Kept in memory in the extension, like approvals, and listed by `blackice pending` under "Denied recently". |
| Ad hoc signed code | Ask mode asks about it too, and the approval names its cdhash plus the host: `blackice approve --cdhash … --host …`. A rebuild changes the cdhash, so the next connection asks again. Rules in `blackice.toml` never name it, so block-all drops it. Code with no signature has no cdhash either and is dropped. |
| Host and address | Before a rule or an approval counts, the host is resolved with the system resolver and the flow's remote address must be among the answers, which are kept for 30 s. A mismatch means no rule or approval matches: ask mode asks, block-all drops, and the log says `address_mismatch`. On TCP port 443 a flow that a rule, the Apple services table or an approval would allow is then held until its TLS ClientHello is read, with a host name from the system as with one from DNS answers (below): the server name must be that host, or a host covered by itself whose address checks out, or the flow is dropped (`server_name_mismatch`). The host name from the system is the app's choice, and the server name picks the site behind a shared address. The hold ends at the hello, within the time held flows get (see "Waiting for the hello"). In ask mode such a flow is still asked about by its host name before it connects, and an approval resumes it into the hold. An address entry in a rule and an approval of an address skip the lookup and the server name: they name the destination itself (see "Address rules" and "Connections by address"). |
| Waiting for the hello | A flow held for its TLS ClientHello may stay quiet for 120 s before its first byte, and has 10 s from that byte for the whole hello (decided on 5 November 2026). Until then it had 10 s from the connect, and on the Mac fx and Claude Code, both Bun apps, lost 175 connections in two days to it as `server_name_timeout`: an app can open a connection and write nothing for a while, the spare of two opened at once or one kept ready for the next request. No byte passes before a verdict either way, so the longer wait lets nothing through; a held flow keeps one of the 256 places. One dropped quiet is logged `idle_before_hello`, one whose hello started and did not finish in 10 s `server_name_timeout`, and one the app closes before writing `closed_before_hello`, as before. |
| Apple services | macOS's own services pass without a rule, through a built-in table (`macos/Sources/BlackiceCore/AppleServices.swift`) of signing identifier → the Apple hosts that service uses. An entry counts only for Apple platform code (no Team ID, `anchor apple`) and only when the address checks out, as for a rule; the log says `apple_service`. The table comes from the ask-mode runs' event logs plus well-known services; on 5 November 2026, 34 services seen on 3 and 4 November reaching only Apple's domains were added, most with only the hosts they reached, and those on an iCloud host named after the account's partition (`p404-…`) with `*.icloud.com`. Tools that run commands or fetch any URL (curl, nscurl, python3, perl, ruby, the shells, ssh, scp, nc, git, osascript, Safari, WebKit's networking process, nsurlsessiond) are never in it, and a test checks that; Safari's Safe Browsing service is, to its one host. Neither is accountsd, which signs in to accounts of other providers, and dataaccessd and the contacts sync get iCloud only: a Google account needs a rule. trustd and ocspd get Apple's hosts and those of the main public certificate authorities, not any host on port 80: a certificate names its own OCSP, CRL and issuer URLs, so any app could reach a host of its choosing through trustd. On by default; `apple_services = false` turns it off. |
| Any destination | `hosts = ["*"]`, alone in a rule, lets that app reach anything, including flows with an address and no host name, in block-all and ask. No host or address check applies, and the log says `rule_line_N`. For VPN clients and DNS proxies, which connect by address, and for a browser you would allow everywhere anyway. Everything the app does is then allowed. `*` next to other hosts is an error. For an app that reaches a few known networks, address and CIDR entries are narrower (see "Address rules"). |
| Address rules | `hosts` in `[[allow]]` takes IPv4 and IPv6 addresses and CIDR ranges next to host names, as in `hosts = ["100.64.0.0/10", "10.0.0.5", "fd7a:115c:a1e0::/48", "*.ts.net"]` (decided on 4 November 2026). An address entry matches a connection whose remote address it holds, with or without a host name, in block-all and ask, and the log says `rule_line_N;address`. No lookup and no server name check apply, since the rule names the destination itself: on port 443 it allows that address whatever server name the hello carries, and an entry for an address many sites share (a CDN's) covers all of them there. Name entries keep their checks. Entries are read strictly: IPv4 is four numbers from 0 to 255 with no leading zeros (`010.0.0.1`, `10.1` and `0x0a.0.0.1` are errors, because parsers disagree on them); a prefix is a decimal number from 1 to 32 or 128; no bit may be set after the prefix (`10.0.0.5/8` is an error that names `10.0.0.0/8`, so a typo cannot widen a rule unseen); `0.0.0.0/0` and `::/0` are errors that point to `*`; a zone (`%en0`) and an IPv4-mapped IPv6 address are errors. A rule names no interface, so a link-local entry matches on every one. Addresses count toward the 256 entries of a rule, and one address or range written twice is an error. |
| Loopback | Connections to 127.0.0.0/8 and ::1 pass in every mode, logged as `loopback`, before the app is identified and before any rule or host check (decided on 4 November 2026). IPv4-mapped loopback is IPv4 by the time the policy sees it, so it counts too. `loopback = false` in `blackice.toml` filters them like any other connection. Tools talk to services on the same Mac this way: on the Mac on 4 November, ask mode dropped the Tailscale CLI's connection to its app at 127.0.0.1:49160 as `no_host`, with no event. The trade-off: any app can use a proxy or relay that listens on loopback. The proxy's own connection out is still filtered, under the proxy's identity, so this matters only where that app may reach more than the first one could, such as a VPN client with a `*` rule that offers a local SOCKS or HTTP proxy. |
| Connections by address | In ask mode a TCP connection with no name (no host name from the system, not exactly one name from DNS answers) that is not on port 443 is asked about by its address (decided on 4 November 2026). Until then it was dropped as `no_host` with no event, so `ssh` to a Tailscale address failed at once and nobody was asked. The event's `host` is the address, the same text as `ip`: dotted IPv4, IPv6 lower case and compressed as in RFC 5952, a link-local address with its interface index after `%`. One event per app, address and port, as for names. An approval can name an address, by hand (`blackice approve --app com.apple.ssh --host 100.66.32.75 --for 1h`) or as a hook's answer to such an event. It covers only connections to that exact address that have no name, and needs no lookup, since the address is the destination; a connection with a name is asked about and approved by its name. On TCP port 443 the server name is read first, as before, and a hello with no server name, which is what a client sends when it connects to an address, is asked about by its address instead of dropped (reasons end in `;sni_missing`). With no server name there is no site name to check, and the approval names the address the connection goes to, so that is as safe as off port 443. Not asked about, and dropped as `no_host` with no event as before: UDP with no name, since WebRTC, games, discovery and QUIC would fill the hook queue with events that get denied anyway, while the need was `ssh` and other TCP to one's own hosts (address entries, `*` and loopback still allow UDP); a multicast or broadcast destination (224.0.0.0/4, 255.255.255.255, ff00::/8; a subnet's broadcast address is not recognized, since that needs the interface's netmask, but it is UDP anyway); a link-local address whose interface is not known, which could be any host on any link; a connection with no port. A host name from the system that is only the remote address written out (an app that opened `https://100.66.32.75/`) counts as no name. Block-all keeps dropping such connections (`no_host` for an app with a rule, `no_rule` otherwise) unless an address entry or `*` covers them. |
| Names from DNS answers | In ask and block-all the extension reads the system resolver's DNS traffic (mDNSResponder's port-53 flows, UDP and TCP) and passes every byte unchanged; accept-all reads nothing. A response counts only when it answers a query sent on the same flow, with the same ID and question, the check the resolver applies itself. The question's name is recorded against the A and AAAA addresses at the end of its CNAME chain (never the CNAME targets), for the records' TTL held between 30 s and 5 minutes, at most 16 names per address and 4096 addresses. Anything malformed, truncated or not understood teaches nothing. A connection with no host name from the system whose address was given for exactly one name is decided on that name, which passes the host and address check since it came with the address: rules and approvals for it count, and ask mode asks about it. On port 443 the TLS server name is still read, and a server name other than that one must be covered itself, or the connection is dropped (`server_name_mismatch`), so an app cannot look up an allowed name and then reach another site on the same CDN address. Several names for one address, or none, leave the server name path as it was; a TCP connection off port 443 is then asked about by its address in ask mode (see "Connections by address"). |
| Encrypted Client Hello | A ClientHello with the `encrypted_client_hello` extension (ECH) is judged on its server name in the clear, like any other: it must be the flow's host, or a host covered by itself whose address checks out, or the connection is dropped (`server_name_mismatch`). Its verdict's reason ends in `;ech` (`rule_line_3;server_name;ech`, `server_name_mismatch;ech`), so `log show` can count such hellos. A decoy ECH extension (GREASE), which Chrome sends when it has no ECH key for the server, leaves the real host in the clear, so it passes as without ECH. Real ECH puts the provider's public front end there (`cloudflare-ech.com`, say), which is not the host the app named, so the connection is dropped unless the front-end name is covered itself. The limit: the site the connection reaches is in the encrypted part, which blackice cannot read, so a rule or an approval for a front-end name covers whatever site sits behind it. Allowing or approving such a name (`cloudflare-ech.com` and the like) gives that app the provider's whole network. And the app writes the name in the clear itself: where a provider decrypts ECH whatever that name says, any covered name it hosts can serve as the front end. Dropping every ECH hello was considered and rejected (4 November 2026): GREASE looks the same as real ECH, so it would break apps built on Chromium and, if macOS's own TLS sends ECH, Apple's services and the deciding agent. |
| DNS in block-all | Apple's resolver stays reachable on port 53 in every mode, so in block-all any app can still make name lookups through it, which can carry data out. Documented as a known gap; tying DNS answers to rules with an `NEDNSProxyProvider` is later work. |
| Hooks that leave their process group | Best effort, and documented: a process started by a hook that calls `setsid` or `setpgid` escapes the kill at the deadline and when the hook exits, and can write to the hook's stdout until the daemon stops reading it, 0.2 s after the hook exits. Running hooks under a separate user or in a sandbox would close this; neither is planned yet. |
| Approval storage | In memory, inside the extension. Permanent rules live in `blackice.toml`. |
| Who can approve | A person, with `blackice approve` or `deny` and Touch ID, or a hook, through the daemon (decided on 4 November 2026, for 0.4.0). The event's one-time token never leaves the extension and the daemon: a hook gets the event without it and answers on its stdout, and the daemon sends that answer to the extension with the token. The extension takes an answer with a token only on the connection of the daemon it registered. `approve` and `deny` take no `--token`. |
| Hook answers | A hook answers only when it exits with status 0 before its deadline. The last non-empty line of its stdout, trimmed, must then be exactly `deny`, `approve <N>m` (N from 1 to 1440) or `approve <N>h` (N from 1 to 24), the limits of `approve --for`. The daemon reads at most 64 KiB of stdout; more than that, any other line, another exit status or the deadline is no answer, and the connection is denied at its deadline. The answer names no app and no host: the daemon takes both from the event, so an answer to an event whose host is an address approves or denies that address. The event log records `hook_answer` (the answer and its seconds) or `hook_no_answer` (a reason, and at most the first 24 characters of an unrecognized line, printable ASCII only), and `answer_refused` when the extension refuses the answer. |
| Hook programs | `program = "/abs/path"` with `app` and `team`, the identity pair of `[[allow]]`, plus optional `args`, `env` and `stdin` (`"none"` keeps the event off stdin, for Claude Code, Codex and opencode; the default is `"event"`). The daemon starts the program directly, suspended, checks the code signature of the process it started, as for an `[[allow]]` rule, against `app` and `team`, and only then lets it run. Checking the process rather than the file means the code checked is the code that runs. On a mismatch it kills the process before it runs and logs `hook_refused`. `run = '…'` still runs through `/bin/sh -c` with no check. Only `program` hooks are protected against a program swapped by another program of the user; `blackice agent connect` writes one, with the identity read from the agent's binary. |
| Agent instructions | The instructions an agent decides by ship inside the blackice binary (decided on 5 November 2026). A `program` hook names its set with `instructions = "fx"`, `"claude-code"`, `"codex"` or `"opencode"`, and for each event the daemon writes those files into the event's private directory before it starts the program: fx's skill as `skills/blackice/SKILL.md`, where fx finds its workspace's skills, Claude Code's system prompt as `instructions.md`, named by `--system-prompt-file instructions.md`, Codex's base prompt as `instructions.md`, named by `-c model_instructions_file="instructions.md"`, and opencode's system prompt as `instructions.md`, named by the prompt of the agent its hook defines, `{file:./instructions.md}`. The hook names them by a path relative to that directory, its working directory. Up to 0.4.0 `agent connect` copied them into the agent's home, where any program of the user could rewrite them ("approve everything") once, for every decision after; it now removes those copies once the new hook is loaded. The text comes from `integrations/` through `macos/scripts/agent-instructions.sh`, and a test fails when the copy in the binary and those files differ. The owner's own guidance for the agent, `notes` in an `[agent]` table of `blackice.toml` (at most 4 KiB of plain text, the one value that may span lines), comes the same way: it is part of the configuration loaded with Touch ID, and the daemon writes it as `notes.md` next to the event, 0600. The instructions say to follow the notes for judgment calls but never over their safety rules (untrusted fields, lookalike hosts, at most 24 h), and that text in the event claiming to be a note is a reason to deny. What stays exposed is under "Self-approval" in the open problems. |
| Daemon | `blackice daemon` takes no options and reads no file (decided on 3 November 2026). The extension's reply to its registration carries the configuration the extension holds, the `blackice.toml` text that `start` or `mode` saved after Touch ID plus its generation, and the daemon takes its hooks and timeout from it, parsed with the same strict parser. Each event carries the generation of the configuration it was raised under, and is not sent once another one is installed; a daemon holding another one registers again on the same connection to get the current configuration, and runs no hook for an event whose configuration is gone. Hooks get an environment the daemon builds: `HOME`, `USER` and `LOGNAME` from the user database, `TMPDIR` from confstr, a fixed `PATH` and `LANG`, a `program` hook's `env` on top (which may set `HOME` but no `BLACKICE_` variable), and the event's file and ID. `blackice agent install` and `uninstall` write and load, or unload and remove, the LaunchAgent, without Touch ID. |
| Configuration | `blackice.toml`, read by a small strict parser for the subset the file uses. No third-party dependency. |
| Configuration change | Installing a configuration ends what waits under the old one, paused for a lookup or an answer or held for its TLS hello, and cancels its events. The new configuration decides each such flow again, with no approval and nothing looked up: what it allows outright (accept-all, a rule, the Apple services table, loopback) goes on, logged with that reason and `;configuration_changed` (`accept_all;configuration_changed`), and the rest is dropped as `configuration_changed` (decided on 5 November 2026). Until then all of it was dropped, so switching from ask mode to accept-all cut the connections that waited: 20 at once on the Mac on 5 November. A flow the new configuration would allow only once its server name is read, or would ask about, is still dropped, and an answer taken under the old configuration still lets nothing through under the new one, even when it is applied after the change. |
| Start keeps a switch | `blackice mode` and the menu's Mode change the mode, and who answers in ask mode, in the configuration blackice holds, never in the file. `blackice start` keeps such a switch while the file still has what it had at the last start, and says so before Touch ID; once the file's own `mode` or `answers` changes, the file wins (decided on 5 November 2026). Until then every `start` loaded the file's mode, so an upgrade's `start` on 5 November 2026 switched a Mac from accept-all back to the file's ask mode and cut a running Claude Code session. The mode needs no record: a mode switch leaves the text's `mode` line as the file had it. A switch of `answers` rewrites that line, and leaves a comment on it with the file's own value (`answers = "codex"  # set by blackice mode; blackice.toml has "fx"`), which later switches keep; a text switched by 0.4.2, with no comment, counts as switched when it differs from the file only in that line. An agent whose hook is gone from the file gives way to the file's `answers`. `agent connect`, and the first `start` right after its questions, load the file as written. |
| Menu bar | Blackice.app opened as an app, or `blackice menu`, runs in the menu bar (4 November 2026). It shows the state and answers by hand through the same code as the CLI, Touch ID included, and adds no privileged path. Starting, stopping, rules, agents and the daemon stay in the CLI. Quitting it leaves filtering as it was. |
| Apple account | Individual Developer Program membership. |

## Architecture

- **Blackice.app**, installed in `/Applications`, with no window. It contains the network extension and the
  `blackice` binary, which is also its menu bar app. macOS activates system extensions only from an app in
  `/Applications`.
- **The menu bar app** runs when LaunchServices opens Blackice.app (Finder, Spotlight, `open`, or at login) or with
  `blackice menu`. LaunchServices starts an app as a child of launchd with no arguments and no terminal; anything else,
  `blackice` with no arguments in a terminal included, is the CLI. One copy runs at a time (a lock file in the user's
  temporary directory). The mark is full in ask and block-all and dimmed when blackice is off, in accept-all or not
  reachable, with the number of waiting connections next to it. The mode is the one the extension says it decides with,
  and, as in `blackice status`, the menu says when that is not the saved configuration, or when an unfinished upgrade
  keeps the extension out of reach (`NESystemControl.unfinishedUpgrade`). Its menu shows the mode, the waiting
  connections with Allow for 10 minutes, Allow for 1 hour and Deny, the latest verdict from the event log on one line
  (the last five in its submenu), a warning for an hour after a `hook_refused`, a mode switch, Stop Filtering, the version and Quit Menu; a
  line about hooks shows up only when the daemon that runs them is not running. Since 5 November 2026 (a tester's
  "minimal and clean") it has no file, documentation or login items: opening at login is `blackice menu --login on|off`
  (`SMAppService.mainApp`, for the signed app in `/Applications`). It reads
  the filter preference and the extension's pending list every 5 s, without Touch ID; answers and mode changes go
  through `NESystemControl`, the code behind `blackice approve`, `deny` and `mode`, and ask for Touch ID each time. It cannot
  start or stop blackice, change rules, connect an agent or install the daemon, and quitting it leaves the filter and
  the daemon running. App names and hosts come from whoever opens the connection, so the menu drops control and
  format characters (bidi overrides among them) and cuts long names. The model is in plain Swift with unit tests;
  `macos/Sources/BlackiceMenu/SystemAdapter.swift` holds every call into status, pending, mode, approve and deny.
  Not yet run as the signed app: Touch ID from the menu and the XPC reads.
- **The extension** (`NEFilterDataProvider`) decides right away in accept-all and block-all. In ask mode it pauses
  the flow, sends an event to the daemon over XPC, and resumes the flow when an answer arrives or the timeout passes.
- **`blackice daemon`** runs as a LaunchAgent for the user, receives events and runs the hooks. The extension
  cannot start processes.
- **`blackice approve`** reaches the extension over XPC after Touch ID, adds a temporary rule and releases matching
  paused flows. The daemon sends a hook's answer the same way, with the event's token.

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
   and holds events, hooks and verdicts. Since 5 November 2026 a line names the app in the clear after the verdict
   and reason (`flow drop timeout app=ABCDE12345/com.example.tool`), so the log tells which apps lost connections;
   the host and the rest stay private.
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
   In 0.4.0 hooks get no token and answer on stdout (see "Who can approve" and "Hook answers" under the
   decisions), so the runner no longer replaces anything in their stderr, and `program` hooks are started only
   when their signature checks out. Not yet run on a Mac.
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
   In 0.4.0 fx runs nothing: it reads the event with its file tool and ends its reply with the answer line, and its
   rules refuse every command. `agent connect` writes a `program` hook for fx, with the signing identifier and Team
   ID read from fx's binary, and its test reads fx's last line. The eval reads the same line with the daemon's
   rules. Neither has run with a model yet: on 4 November 2026 the one run against the sample event stopped at AI
   Gateway, whose team had no credits left (HTTP 502, `insufficient_funds`), with nothing on stdout.
   A second decider, written on 4 November 2026 and not yet run under the daemon: Claude Code in print mode
   ([`integrations/claude-code/`](../integrations/claude-code/README.md)), with reading the event as its only tool,
   a sign-in of its own (its own `CLAUDE_CONFIG_DIR`, kept in the login keychain, so the hook keeps `HOME`) and a
   rule for `api.anthropic.com` and `platform.claude.com`. `blackice agent connect claude-code` writes its
   `program` hook as `connect fx` does, with `stdin = "none"`: `claude -p` adds stdin to its prompt, and the event
   should reach it only as the file it reads. One agent answers at a time: since 0.4.2 each connected agent keeps
   its hook, and `answers` in `[agent]` names the one that runs (or `you`), switched with `blackice mode ask --agent`
   or the menu's Mode.
   Another decider, written on 5 November 2026 after 0.4.2: opencode 2.2.5
   ([`integrations/opencode/`](../integrations/opencode/README.md)), with a provider picked at `agent connect`,
   a `HOME` of its own for that provider's sign-in, reading the event's directory as its only tool, and a rule for
   that provider's hosts. Each provider's host was checked with a key that was not one, through a proxy that
   logged what opencode reached. With a ChatGPT sign-in and `gpt-6-luna` it decided the 23 eval cases as expected,
   reaching `chatgpt.com` only; with Z.AI's `glm-5.3-flash` it decided 22, and approved Slack on port 6667.
   [`integrations/eval/run.sh`](../integrations/eval/run.sh) runs any decider over the same 20 events the way the
   daemon runs a program hook; Claude Code 2.1.317 with Sonnet decided all 20 as expected, twice (as a `run` line,
   then as a program hook), in 3 to 8 s each.
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
   Since 5 November 2026 that change, the switch to accept-all, lets them go instead
   (`accept_all;configuration_changed`; see "Configuration change" under the decisions), and the script checks
   that; not yet run on a Mac.
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
   answered. The logs of later failed upgrades show why: the replaced build's process still held the XPC service
   name that every build shared. After 0.3.2 each build has its own (see "Upgrades in place" under the open
   problems). Build 4 replaces the token in the hooks' stderr (P2-02), which the builds of the earlier fx runs did
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
- **Self-approval.** Any program of the user can run `blackice approve`, and needs Touch ID to get anywhere.
  Since 0.4.0 the event's token stays in the extension and the daemon: it is not in the event file, the hook's
  stdin or environment, or any command line, so a program cannot read it there and answer in the hook's place. A
  hook's answer covers only its event's app and host. What is protected: a program of the user cannot take the
  token and answer in the hook's place, and no answer reaches beyond the app and host of the event it was given.
  What is not, against a program running as the same user:
  - It can steer the hook into approving, its own connection included: rewrite `event.json`, or the instructions
    and notes the daemon wrote next to it, while the hook reads them, so that the event shows a trusted app or the
    instructions say to approve. The event's directory has a random name but belongs to the user, so this takes a
    program that watches the hooks' directory and wins a race each time. Or it can change what the agent still
    reads from its home. The instructions no longer live there (see "Agent instructions" under the decisions),
    but fx still loads its rules, its sign-in and any other skill from its home: a skill added there sits next to
    the blackice one, and one also named blackice may be read in its place. Claude Code reads only its sign-in and
    state there: `--restricted` and `--safe-mode` ignore its settings, CLAUDE.md, skills and hooks. Codex 0.166.0
    ignores its `config.toml`, rules and hooks there with the hook's flags, but still reads `AGENTS.md` from its
    `CODEX_HOME` as global instructions, and lists the skills in it; no flag turns that off. opencode 2.2.5 gets
    its global configuration folder in the event's directory (`XDG_CONFIG_HOME=.`), so it loads no
    configuration, `AGENTS.md`, plugin or skill from its home, but keeps its sign-in and sessions in a database
    there, which also has a table of permissions; whether a row there could undo the hook's denials has not
    been checked. The daemon then
    approves the app and host of its own copy of the event, which are the program's, for at most 24 h. Closing
    this needs the hook and its files out of the user's reach, under another user or in a sandbox; neither is
    planned yet.
  - A `run` hook's program is not checked, so the program can be replaced with one that prints `approve 24h`.
    A `program` hook is checked against its signature each time it starts, but a signed program that does what
    its files say can still be steered through those files.
  - It can stop the daemon or keep it busy, and connections then wait and are denied at their timeout.
  - The daemon's memory holds the tokens of the events it is answering. The daemon is signed with the hardened
    runtime, so macOS refuses other programs of the user `task_for_pid` on it; that has not been tested on a Mac.
- **Daemon impersonation.** Any program of the user can still run `blackice daemon` and register in place of the
  LaunchAgent, but that copy runs the hooks of the configuration saved with Touch ID, in an environment it builds
  itself (see Daemon under the decisions), so it cannot run hooks of its own. Since 0.4.0 the registered daemon is
  also the only connection whose answers with a token the extension takes, and a copy that registers instead only
  sends what those hooks print. What remains: such a program can keep the LaunchAgent's daemon from getting events,
  by registering again and again or by stopping it, and connections then wait and are denied at their timeout. And
  the programs a hook runs read files that any program of the user can change, such as fx's rules and other
  skills in the agent's home (see "Self-approval"); their instructions come from the daemon.
- **Prompt injection.** Host names, app names and TLS server names are chosen by whoever opens the connection, and
  they reach the model's prompt. Events carry them as structured fields. A hook's only accepted answers are a
  `deny` line or an `approve` line with a duration of at most 24 h, and the app and host come from the event, not
  from the answer, so injected text can at most change the answer for the connection that carried it.
- **Latency and volume.** A model takes seconds and a Mac opens hundreds of connections. Rules, expiring approvals
  and one event per repeated connection keep the questions to new destinations. The Mac's event log of 3 and 4
  November 2026, in ask mode: about 670 paused connections in two days for about 144 app and host pairs, with a few
  pairs asked about again and again (one ad hoc Homebrew binary 52 times, mostly denied), and the agent took 13.8 s
  at the median (22 s at p90), longer than the 8 s a connected flow is held. Ten minutes with a broken agent dropped
  266 connections at the deadline, 74 at the server name deadline, 71 as `hold_expired` and 50 as `tls_unparsed`.
  Since then the log names the app of each line, accept-all runs ask mode dry, and `blackice report` sums both up
  (see the decisions), so the rules an agent would need can be written before ask mode is on.
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
  - A TCP connection with no name at all, and no server name, was dropped as `no_host` with no event until 4
    November 2026; ask mode now asks about its address (see "Connections by address"). Not yet run on a Mac. Off port 443
    nothing is read before the event, so a TCP connection waits up to the whole timeout; whether the server keeps
    it that long depends on the protocol (an SSH server waits two minutes for the login by default).
  - A connection blackice drops fails in the app with "Bad file descriptor" (EBADF) when it connects. On the Mac on
    4 November 2026, `ssh` to a Tailscale address and the Tailscale CLI both failed with `connect: Bad file
    descriptor`, which reads like a bug in the app or a network fault rather than a firewall. NetworkExtension's
    drop verdicts (`NEFilterNewFlowVerdict.drop()`, `NEFilterDataVerdict.drop()`) take no error code, and no other
    verdict refuses a flow, so blackice cannot make it say "connection refused". The install and configuration docs
    say what the message means.
- **The Mac's own services in ask mode.** With only the demo's rules, iCloud, CalDAV, Software Update, Maps and
  AuthKit were paused and then dropped at the deadline, and the demo's three events were a few among dozens. The
  Apple services table (see the decisions) now covers those and other well-known services. In the build 4 run
  (P2-02) 13 flows passed as `apple_service`, and still asked about were nsurlsessiond (kept out of the table on
  purpose), tipsd (added to the table since), a Google calendar synced by dataaccessd (which needs a rule), and
  cloudd reaching gateway.icloud.com, which the table covers but whose address check failed. The 0.3 runs of 3
  and 4 November asked about 34 more services that reached only Apple's domains (Find My, Apple Media Services,
  Siri and Spotlight suggestions, Private Cloud Compute and others), all in the table since 5 November; not yet
  run on a Mac. A service or host missing from the table is still asked about. A service's UDP flow with no host name is still dropped
  (`no_host`), and Apple's CDN answers can fail the address check. The mode also stays on until someone
  switches it with Touch ID: when the demo's window closed early, the Mac kept pausing every new connection.
- **VPN and DNS proxies.** With Tailscale's DNS on, the system's lookups go to 100.100.100.100 through Tailscale's
  extension, which forwards them with its own sockets by address: flows with no host name, which blackice drops
  (`no_host`), so names stop resolving in ask and block-all. Ask mode asks about TCP with no name since 4 November
  2026, but these lookups are UDP and raise no event. The demo ran with `tailscale set --accept-dns=false`.
  A rule with `hosts = ["*"]` for the extension now allows those flows; the docs use the standalone build's
  identity, read with `codesign -dv` on the test Mac (`io.tailscale.ipn.macsys.network-extension`, team
  W5364U7YZB). It has not been seen at work on a Mac yet: in P2-02 the rule was loaded but allowed nothing. What
  remains: blackice ships no such rule, so each VPN client or DNS
  proxy needs one from the user, and the rule allows everything that extension does.
- **Repeated denials.** After a deny, the app's next try (`curl` moving on to another address) raised a new event,
  and the agent was asked again: on the Mac on 3 and 4 November, one ad hoc binary was asked about 52 times and
  another 45 times, mostly denied each time. Since 5 November 2026 a deny is remembered for 10 minutes (see
  "Remembered denials" under the decisions). Not yet run on a Mac. What remains: no answer in time is not
  remembered, on purpose, so a broken or slow agent still costs one question per deadline, and a pair is asked
  about again 10 minutes after its deny.
- **Touch ID count.** `start`, `stop` and `mode` each ask for Touch ID, so a demo takes two. A short unlock
  window, like sudo's, is a candidate. A test that needs a person at the keyboard can also fail for that reason:
  the fault test's second Touch ID was cancelled, and the check that depends on it failed (P5-01).
- **Upgrades in place.** On 3 November 2026, on macOS 27.0.1, build 4 put in `/Applications` over build 3 and
  activated with `blackice start` replaced the running extension, which kept filtering but had no Mach service:
  `launchctl print` showed it with no endpoints, and lookups of its XPC service failed with "No such process". The
  daemon, `pending`, `approve` and `deny` could not reach it, so ask mode dropped everything it paused at the
  deadline. A restart fixed it; P2-02 is the same build after the restart. `blackice start` now checks, after macOS
  replaces a running extension, that its XPC service answers, and if it does not, says to restart and exits with
  status 75. The upgrade from build 4 to build 5 with Homebrew did the same, and the check caught it
  ([P5-02](../evidence/P5-02-homebrew-upgrade-from-release-macos.md)). The upgrade to build 15 answered at once, but
  the build 14 it replaced had been activated over build 13 that morning and had never been reachable, with no
  restart in between ([P5-09](../evidence/P5-09-hook-queue-faults-0.3.2-candidate-macos.md)).
  The cause, from the Mac's logs of three failed upgrades (4 November 2026): nesessionmanager runs each version of
  the extension as its own launchd job, labelled with the version
  (`NetworkExtension.com.valentorassa.blackice.filter.0.3.1.14`), and up to 0.3.2 every version's job declared the
  same Mach service, `M294LK997M.com.valentorassa.blackice.filter`. During a replace it ends the old job and
  submits the new one 4 to 6 ms later. The old process still holds XPC transactions open and lives until launchd's
  5 s exit timeout, so launchd refuses the new job's endpoint ("The endpoint … already exists and is owned by" the
  old version, then "failed activation … error = 1: Operation not permitted"). The new extension's listener has no
  endpoint, though it logs `xpc_listening ok` (`resume()` reports nothing); then the old job is removed, the name
  is gone, and every lookup fails with "No such process" until a restart. When the old process had already exited at
  submit time, nobody held the name and the upgrade worked, so upgrades alternated between failing and working.
  The fix, after 0.3.2: each build has its own name, ending in its `CFBundleVersion`
  (`M294LK997M.com.valentorassa.blackice.filter.16`), still under the app group as NetworkExtension requires.
  `sign.sh` writes it into the extension's Info.plist and `package.sh` checks it. The extension listens on the name
  in its own Info.plist; the CLI and the daemon look up the one in the Info.plist of the extension inside their
  `Blackice.app`, and both sides check it with `Peers.machServiceName`, so they read one value from one file. The
  extension now logs `xpc_listening` with the name. Until `start` activates the new build, the new CLI cannot reach
  the old extension, so a hook's `approve` or `deny` fails too and in ask mode its connection waits for the
  deadline. `status`, `pending`, `approve` and `deny` then compare the build macOS runs with the app's and say to
  run `blackice start` to finish the upgrade. The daemon already exits when its connection to the old
  extension ends, and launchd starts the new binary, which looks up the new name. The check after `start` stays.
  [`install.md`](install.md) says to restart only when it fails, and always for 0.3.2 and earlier. It needs a signed
  run to confirm: two consecutive signed builds, the second put over the first, with `start` exiting 0 and the
  daemon registering again, no restart.
- **Events with no connection left.** In P5-01, `blackice pending` failed with "the network extension sent an
  invalid reply: events has an invalid entry": an event whose paused flows were all dropped with `hold_expired`
  stays pending, by design, and is listed with 0 connections, while the CLI's check of the reply required at
  least 1. Fixed after that run: the check takes 0, and `pending` shows "no connection left (an approval covers
  the next try)" (`CLITests`). Not yet run on a Mac.
- **Limits of the host check.** The system resolver may answer blackice's lookup differently than it answered
  the app (round-robin, CDNs, split DNS), which shows as a mismatch: ask mode asks and block-all drops. And a match
  proves only that the name resolves to that address now, not who controls the name. The server name is read only
  from TCP on port 443, and from the clear part of an Encrypted Client Hello: a rule or an approval for an ECH front
  end, such as `cloudflare-ech.com`, covers every site behind it. On another port, over UDP (QUIC) or in the HTTP
  `Host` header, an app with a rule for one
  host can still name another site behind the same address.
  Address entries in rules, and approvals of an address, check no name at all. On port 443 an address entry
  allows whatever server name the hello carries, so an entry for an address many sites share, such as a CDN's or a
  cloud provider's, covers every site behind it for that app. An approval of an address covers only connections
  to it with no name, and on port 443 only a hello with no server name.
- **Hook limits.** The limit of 4 hooks at once, at most 256 hooks waiting for a slot, the 10 s a waiting hook needs
  left to start (or the whole timeout, when that is shorter), the 2 s grace period, the 4 KiB of stderr kept per
  hook and the 64 KiB of stdout read for its answer are first guesses, set in code rather than in `blackice.toml`.
- **Log rotation.** The event log only grows. Rotation, or leaving it to newsyslog, is not decided.
- **Installation.** No dialog per connection, but macOS asks once to allow the extension in System Settings, unless
  the Mac is managed with an MDM profile.
