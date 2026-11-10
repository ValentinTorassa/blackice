# Plan

1.0.7 is blackice's current release ([`CHANGELOG.md`](../CHANGELOG.md)), and it has run on one Mac. This file holds the phases, the decisions
taken so far and the open problems. A phase is done when its check passes on a real Mac, not when the code compiles,
and each run on a Mac is recorded in [`evidence/`](../evidence/).

## Decisions

| Topic | Decision |
|---|---|
| Name | The product ships as blackice (decided on 2 November 2026). The first proof of concept, also called blackice, is archived as [ValentinTorassa/blackice-poc](https://github.com/ValentinTorassa/blackice-poc). |
| Repository | Its own repo. Swift files come from blackice-poc's macOS app filter, with the source commit noted in each file. |
| Language | Swift for the extension, the CLI and the daemon. |
| Ask mode | Asks only about connections that no rule or current approval covers. |
| Dry run of ask mode | In accept-all the extension still allows each new flow at once, with no hold, lookup, event or data read, and its log line adds what ask mode would decide then with the same rules (`would=rule_line_3`, `would=apple_service`, `would=ask`, `would=read_server_name`, `would=drop:no_host`), from the same `FilterPolicy.decide` on the configuration seen in ask mode (decided on 5 November 2026). What accept-all does not know is assumed: every address matches its host, no approval or denial counts, and no DNS answer is read, so a connection with no host name from the system is judged by its address. On port 443 a host the app named that a rule or the table covers is judged as if the hello named it (`rule_line_3;server_name`). `blackice report [--last 1h]` sums the log up with `log show`: drops by reason and app, connections paused to ask by app, and the dry run by app. macOS does not keep every line: on a Mac whose data volume was 99% full, `log show` kept none of the filter's (6 November 2026). Each event in the daemon's `events.jsonl` comes from an ask line, so when the daemon logged more events over the same span than `log show` has ask lines, the report says its counts are low. |
| No answer in time | Deny after N seconds. N is configurable. macOS keeps a paused TCP flow as long as we want, so what bounds N is how long the app and the server wait (see the open problems). |
| Approval scope | One app (by signing identity) and one host, with an expiry: `blackice approve --app … --host … --for 1h`. The host may be an IP address, for a connection with no name (see "Connections by address"). |
| Remembered denials | A deny, from a hook, `blackice deny` or the menu, is remembered for 10 minutes for its app and host, any port (decided on 5 November 2026). In ask mode their new connections are then dropped at once as `denied;remembered`, with no lookup, no event and no hook, where they would have been asked about; a rule still allows what it names. A timeout or a hook with no answer is not remembered. An approval of the pair replaces the denial, a deny of an approved pair replaces the approval, and a configuration change or a stop forgets them all. Kept in memory in the extension and, unlike approvals, never saved; listed by `blackice pending` under "Denied, dropped without asking". |
| Ad hoc signed code | Ask mode asks about it too, and the approval names its cdhash plus the host: `blackice approve --cdhash … --host …`, for at most 24 h. An `[[allow]]` rule can name it too, by `cdhash = "<40 lower-case hex>"` in place of `app` and `team`, with `hosts` as in any rule (decided on 6 November 2026). Developer tools installed with Homebrew (its bottles are ad hoc signed on arm64), uv, pipx, npm, nvm or `go install` are ad hoc code, and until then the only lasting permission for one was an approval of one host for 24 h, one host per Touch ID. A cdhash rule covers that one build, compiled tools such as `gh`, `stripe` or `terraform`, in ask and block-all, with the host, address and server name checks of any rule; code the filter cannot read, named by the kernel's cdhash, counts the same way, since that cdhash names exactly that build too. A rebuild or an upgrade changes the cdhash, so the rule stops matching: ask mode asks again, block-all drops it as `adhoc_code`, and the rule needs the new cdhash. Ad hoc code no rule names is dropped in block-all as before. A cdhash rule never counts for an interpreter: python, node, bun, deno, ruby, perl, php, lua, luajit, tclsh, wish, R, Rscript, julia, osascript and the shells, told by the executable's file name, with any version after it (`python3.14`, `ruby3.3`), as the kernel has it (`macos/Sources/BlackiceCore/Interpreters.swift`). A rule for uv's `python3.14` to `oauth2.googleapis.com` would let every script that python runs, a malicious dependency's included, reach that host, which is the supply-chain case blackice exists for. Such a flow is decided as if the rule were not there, and its reason ends in `;interpreter` (`adhoc_code;interpreter` in block-all, `no_rule;interpreter` when ask mode asks); with no path from the kernel to tell, the rule does not count either and the reason ends in `;no_path`. An interpreter's connections are asked about one by one, and an approval of its cdhash still counts, for at most 24 h: the owner's explicit, time-boxed choice. The name is the only check, since nothing else about ad hoc code says what it is: an interpreter copied under another name keeps the interpreter's cdhash, so a rule matches it only if the owner put that cdhash in a rule. Nor does the cdhash cover more than the program file: ad hoc code has no hardened runtime, so a program that starts it with `DYLD_INSERT_LIBRARIES`, or replaces a library it loads from a folder the user can write (`/opt/homebrew/opt`), runs its own code under that cdhash and reaches the rule's hosts; a notarized app's hardened runtime refuses both unless its entitlements allow them. So a cdhash rule should name only the hosts that tool needs. `blackice.toml` names no path, so nothing is refused when it loads. Code with no signature has no cdhash either and is dropped. |
| Host and address | Before a rule or an approval counts, the host is resolved with the system resolver and the flow's remote address must be among the answers, which are kept for 30 s. Answers 2 s old or older that miss the address are looked up again before they count, since CDNs rotate their addresses on TTLs of a few seconds (outlook.office365.com: 2 to 4 s). A mismatch means no rule or approval matches, and the flow is dropped with `address_mismatch` in the log, in ask mode too when a rule, the Apple services table or an approval names the pair: an approval never releases a flow whose address mismatches, so asking would only hold a hook slot. Ask mode asks about a pair nothing names, since its approval lets the app's next connection through once the address checks out. On TCP port 443 a flow that a rule, the Apple services table or an approval would allow is then held until its TLS ClientHello is read, with a host name from the system as with one from DNS answers (below): the server name must be that host, or a host covered by itself whose address checks out, or the flow is dropped (`server_name_mismatch`). The host name from the system is the app's choice, and the server name picks the site behind a shared address. The hold ends at the hello, within the time held flows get (see "Waiting for the hello"). In ask mode such a flow is still asked about by its host name before it connects, and an approval resumes it into the hold. An address entry in a rule and an approval of an address skip the lookup and the server name: they name the destination itself (see "Address rules" and "Connections by address"). No lookup is made either when a DNS answer the extension read gave the address for the host, or for a name the host is an alias of (see "Names from DNS answers"). |
| Waiting for the hello | A flow held for its TLS ClientHello may stay quiet for 120 s before its first byte, and has 10 s from that byte for the whole hello (decided on 5 November 2026). Until then it had 10 s from the connect, and on the Mac fx and Claude Code, both Bun apps, lost 175 connections in two days to it as `server_name_timeout`: an app can open a connection and write nothing for a while, the spare of two opened at once or one kept ready for the next request. No byte passes before a verdict either way, so the longer wait lets nothing through; a held flow keeps one of the 256 places until a newer flow takes it (see "One app's share"). One dropped quiet is logged `idle_before_hello`, one whose hello started and did not finish in 10 s `server_name_timeout`, and one the app closes before writing `closed_before_hello`, as before. |
| One app's share | One app takes at most a quarter of each table the extension keeps for connections that wait (decided on 6 November 2026): 64 of the 256 places for flows held for their TLS hello, in ask mode 64 of the 256 pending events and 256 of the 1024 paused connections, and 256 of the 1024 connections waiting for blackice's own lookup of their host (since 10 November 2026). Until then each table was shared with no share per app, so one app, an ad hoc program too, could fill the hold with connections that write nothing, or the pending table with connections to many hosts or to many ports of one address, and every other app's new connections were dropped as `hold_capacity` or `ask_capacity`. A new flow held for its hello takes the place of the oldest held flow that has sent no byte yet: its own app's when the app holds its 64, or, when all 256 are taken, one of the app that holds the most. That flow is dropped as `evicted_quiet`, and a byte it sends later finds no place and is dropped too. Only when there is no such flow is the new one dropped, as `hold_capacity_app` or `hold_capacity`. A flow whose hello has started keeps its place. Refusing the new flow at its app's share was rejected: on the Mac on 6 November, entries for Claude Code's sockets that were gone stayed quiet for the whole 120 s (see the open problems), about 70 at once, so its real connections, and the deciding agent's, which is also Claude Code, would have been dropped behind them. A connection over its app's share of the pending table is dropped as `ask_capacity_app`, with no event; an event with no connection left still counts until its deadline. One over its app's share of the lookups is dropped as `lookup_capacity_app`. |
| Apple services | macOS's own services pass without a rule, through a built-in table (`macos/Sources/BlackiceCore/AppleServices.swift`) of signing identifier → the Apple hosts that service uses. An entry counts only for Apple platform code (no Team ID, `anchor apple`) and only when the address checks out, as for a rule; the log says `apple_service`. The table comes from the ask-mode runs' event logs plus well-known services; on 5 November 2026, 34 services seen on 3 and 4 November reaching only Apple's domains were added, most with only the hosts they reached, and those on an iCloud host named after the account's partition (`p404-…`) with `*.icloud.com`. Tools that run commands or fetch any URL (curl, nscurl, python3, perl, ruby, the shells, ssh, scp, nc, git, osascript, Safari, WebKit's networking process, nsurlsessiond) are never in it, and a test checks that; Safari's Safe Browsing service is, to its one host. Neither is accountsd, which signs in to accounts of other providers, and dataaccessd and the contacts sync get iCloud only: a Google account needs a rule. trustd and ocspd get Apple's hosts and those of the main public certificate authorities, not any host on port 80: a certificate names its own OCSP, CRL and issuer URLs, so any app could reach a host of its choosing through trustd. On by default; `apple_services = false` turns it off. |
| Any destination | `hosts = ["*"]`, alone in a rule, lets that app reach anything, including flows with an address and no host name, in block-all and ask. No host or address check applies, and the log says `rule_line_N`. For VPN clients and DNS proxies, which connect by address, and for a browser you would allow everywhere anyway. Everything the app does is then allowed. `*` next to other hosts is an error. For an app that reaches a few known networks, address and CIDR entries are narrower (see "Address rules"). |
| Address rules | `hosts` in `[[allow]]` takes IPv4 and IPv6 addresses and CIDR ranges next to host names, as in `hosts = ["100.64.0.0/10", "10.0.0.5", "fd7a:115c:a1e0::/48", "*.ts.net"]` (decided on 4 November 2026). An address entry matches a connection whose remote address it holds, with or without a host name, in block-all and ask, and the log says `rule_line_N;address`. No lookup and no server name check apply, since the rule names the destination itself: on port 443 it allows that address whatever server name the hello carries, and an entry for an address many sites share (a CDN's) covers all of them there. Name entries keep their checks. Entries are read strictly: IPv4 is four numbers from 0 to 255 with no leading zeros (`010.0.0.1`, `10.1` and `0x0a.0.0.1` are errors, because parsers disagree on them); a prefix is a decimal number from 1 to 32 or 128; no bit may be set after the prefix (`10.0.0.5/8` is an error that names `10.0.0.0/8`, so a typo cannot widen a rule unseen); `0.0.0.0/0` and `::/0` are errors that point to `*`; a zone (`%en0`) and an IPv4-mapped IPv6 address are errors. A rule names no interface, so a link-local entry matches on every one. Addresses count toward the 256 entries of a rule, and one address or range written twice is an error. |
| Loopback | Connections to 127.0.0.0/8 and ::1 pass in every mode, logged as `loopback`, before the app is identified and before any rule or host check (decided on 4 November 2026). IPv4-mapped loopback is IPv4 by the time the policy sees it, so it counts too. `loopback = false` in `blackice.toml` filters them like any other connection. Tools talk to services on the same Mac this way: on the Mac on 4 November, ask mode dropped the Tailscale CLI's connection to its app at 127.0.0.1:49160 as `no_host`, with no event. The trade-off: any app can use a proxy or relay that listens on loopback. The proxy's own connection out is still filtered, under the proxy's identity, so this matters only where that app may reach more than the first one could, such as a VPN client with a `*` rule that offers a local SOCKS or HTTP proxy. |
| Connections by address | In ask mode a TCP connection with no name (no host name from the system, not exactly one name from DNS answers) that is not on port 443 is asked about by its address (decided on 4 November 2026). Until then it was dropped as `no_host` with no event, so `ssh` to a Tailscale address failed at once and nobody was asked. The event's `host` is the address, the same text as `ip`: dotted IPv4, IPv6 lower case and compressed as in RFC 5952, a link-local address with no interface. One event per app, address and port, as for names. An approval can name an address, by hand (`blackice approve --app com.apple.ssh --host 100.66.32.75 --for 1h`) or as a hook's answer to such an event. It covers only connections to that exact address that have no name, and needs no lookup, since the address is the destination; a connection with a name is asked about and approved by its name. On TCP port 443 the server name is read first, as before, and a hello with no server name, which is what a client sends when it connects to an address, is asked about by its address instead of dropped (reasons end in `;sni_missing`). With no server name there is no site name to check, and the approval names the address the connection goes to, so that is as safe as off port 443. Not asked about, and dropped as `no_host` with no event as before: UDP with no name, since WebRTC, games, discovery and QUIC would fill the hook queue with events that get denied anyway, while the need was `ssh` and other TCP to one's own hosts (address entries, `*` and loopback still allow UDP); a multicast or broadcast destination (224.0.0.0/4, 255.255.255.255, ff00::/8; a subnet's broadcast address is not recognized, since that needs the interface's netmask, but it is UDP anyway); a connection with no port. A link-local address is asked about with no interface (decided on 10 November 2026), because a flow has none: on macOS 27.0.1 a connection to `fe80::dead:beef%en0` reached the filter as `fe80::dead:beef`, in the text of the flow's endpoint, in `remoteFlowEndpoint` (build 42 read it and found no interface) and in NetworkExtension's own debug line (`remoteEndpoint = fe80::dead:beef.9`). So its event names the address alone, and an approval covers that address on every interface, as an address entry of a rule does: the same address on another network is another host, and the approval lets the app reach that one too. Until 1.0.7 such a connection was dropped as `no_host` with no event, and `approve --host` took a link-local address only with an interface, which matched no connection; an approval saved that way is left out when the file is read. A connection with a host name to a link-local address is still dropped as `address_mismatch`: the lookup's answers name an interface and the flow does not, so the two never compare equal. A host name from the system that is only the remote address written out (an app that opened `https://100.66.32.75/`) counts as no name. Block-all keeps dropping such connections (`no_host` for an app with a rule, `no_rule` otherwise) unless an address entry or `*` covers them. |
| Names from DNS answers | In ask and block-all the extension reads the system resolver's DNS traffic (mDNSResponder's port-53 flows, UDP and TCP) and passes every byte unchanged; accept-all reads nothing. A response counts only when it answers a query sent on the same flow, with the same ID and question, the check the resolver applies itself. The question's name is recorded against the A and AAAA addresses at the end of its CNAME chain (never the CNAME targets), for as long as the resolver answers from the records (below) with their TTL held between 30 s and 5 minutes, at most 16 names per address and 4096 addresses. Anything malformed, truncated or not understood teaches nothing. A connection with no host name from the system whose address was given for exactly one name is decided on that name, which passes the host and address check since it came with the address: rules and approvals for it count, and ask mode asks about it. On port 443 the TLS server name is still read, and a server name other than that one must be covered itself, or the connection is dropped (`server_name_mismatch`), so an app cannot look up an allowed name and then reach another site on the same CDN address. Several names for one address, or none, leave the server name path as it was; a TCP connection off port 443 is then asked about by its address in ask mode (see "Connections by address"). The CNAME records on the chain from a question's name are kept too, each as long as the resolver keeps it, with its TTL held between 30 s and a day (decided on 10 November 2026): once the addresses at the end of a chain have gone, the resolver asks only for the name they belong to, so the answer that brings the new addresses names the chain's end, or its middle. A name that is an alias, through CNAMEs still kept, of a name an address was given for passes the host and address check for that address like the name itself, at most 64 aliases followed per address. It does not name a connection that has no host name: that is still decided on the one name its address came under, which is then the chain's end and not the host the app asked for. A name or a CNAME lasts as long as mDNSResponder answers from its record, and 5 s more since the extension reads an answer before the resolver does (decided on 10 November 2026): the resolver keeps a record for its TTL, a quarter more and 2 s, and for at least 15 s (`RRAdjustTTL` and `GetEffectiveTTL` in mDNSResponder-2881.120.11; asked for one host twice a second on macOS 27.0.1, it asked the network again 77 s after a CNAME of 60 s, 39 s after one of 30 s, 24 s after 18 s, 20 s after 15 s, and 15 s after addresses of 3 to 9 s). Until then a name lasted its TTL and went while the resolver still handed its addresses to apps. At most 512 DNS flows are read at once, and a new flow takes the place of the one quiet the longest; a flow let go is remembered for two minutes more, at most 4,096 of them, so that its late data passes (decided on 10 November 2026). Until then the table took 256 flows, counted each for two minutes after it was let go, and left a new flow unread when it was full, so a burst of lookups left the answers after it unread for minutes. A flow let go to make room with a query still unanswered is counted each minute in the log (`control dns_flows_unread`): a flow and not an answer, since one flow can wait for several answers or for one that never comes. |
| Encrypted Client Hello | A ClientHello with the `encrypted_client_hello` extension (ECH) is judged on its server name in the clear, like any other: it must be the flow's host, or a host covered by itself whose address checks out, or the connection is dropped (`server_name_mismatch`). Its verdict's reason ends in `;ech` (`rule_line_3;server_name;ech`, `server_name_mismatch;ech`), so `log show` can count such hellos. A decoy ECH extension (GREASE), which Chrome sends when it has no ECH key for the server, leaves the real host in the clear, so it passes as without ECH. Real ECH puts the provider's public front end there (`cloudflare-ech.com`, say), which is not the host the app named, so the connection is dropped unless the front-end name is covered itself. The limit: the site the connection reaches is in the encrypted part, which blackice cannot read, so a rule or an approval for a front-end name covers whatever site sits behind it. Allowing or approving such a name (`cloudflare-ech.com` and the like) gives that app the provider's whole network. And the app writes the name in the clear itself: where a provider decrypts ECH whatever that name says, any covered name it hosts can serve as the front end. Dropping every ECH hello was considered and rejected (4 November 2026): GREASE looks the same as real ECH, so it would break apps built on Chromium and, if macOS's own TLS sends ECH, Apple's services and the deciding agent. |
| DNS in block-all | Apple's resolver stays reachable on port 53 in every mode, so in block-all any app can still make name lookups through it, which can carry data out. Documented as a known gap; tying DNS answers to rules with an `NEDNSProxyProvider` is later work. |
| Hooks that leave their process group | Best effort, and documented: a process started by a hook that calls `setsid` or `setpgid` escapes the kill at the deadline and when the hook exits, and can write to the hook's stdout until the daemon stops reading it, 0.2 s after the hook exits. Running hooks under a separate user or in a sandbox would close this; neither is planned yet. |
| Approval storage | In memory, inside the extension, and saved to a file only root can read or write, so approvals outlast `blackice stop`, an upgrade or a restart of the Mac (decided on 10 November 2026). Each keeps what it had left when saved, less the time of day gone by since; the file is written again each minute, so a clock set back gains an approval at most the minute since. The extension saves them right after an answer, when one expires, each minute and when it stops, and reads them back when it starts. `blackice deny` takes back one app and host, and `blackice deny --all` forgets them all, with one Touch ID (since 10 November 2026): what waits keeps waiting, the remembered denials stay, and connections already let through go on. It works only while blackice is on, since the extension that holds the approvals takes no commands once it is stopped: off, the command says so before asking for Touch ID, and the saved approvals wait for the next start. Remembered denials are not saved. Permanent rules live in `blackice.toml`. |
| Who can approve | A person, with `blackice approve` or `deny` and Touch ID, or a hook, through the daemon (decided on 4 November 2026, for 0.4.0). The event's one-time token never leaves the extension and the daemon: a hook gets the event without it and answers on its stdout, and the daemon sends that answer to the extension with the token. The extension takes an answer with a token only on the connection of the daemon it registered. `approve` and `deny` take no `--token`. |
| Hook answers | A hook answers only when it exits with status 0 before its deadline. The last non-empty line of its stdout, trimmed, must then be exactly `deny`, `approve <N>m` (N from 1 to 1440) or `approve <N>h` (N from 1 to 24), the limits of `approve --for`. The daemon reads at most 64 KiB of stdout; more than that, any other line, another exit status or the deadline is no answer, and the connection is denied at its deadline. The answer names no app and no host: the daemon takes both from the event, so an answer to an event whose host is an address approves or denies that address. The event log records `hook_answer` (the answer and its seconds) or `hook_no_answer` (a reason, and at most the first 24 characters of an unrecognized line, printable ASCII only), and `answer_refused` when the extension refuses the answer. |
| Hook programs | `program = "/abs/path"` with `app` and `team`, the identity pair of `[[allow]]`, plus optional `args` and `env`. Since 1.0.3 (decided on 6 November 2026; it needs macOS 14.4) the daemon starts the program directly with a launch requirement built from `app` and `team`: the kernel runs the code only when it has that signing identifier and Team ID and a Developer ID signature, or, with no `team`, when it is Apple platform code with that identifier, and kills it at exec otherwise. Once it runs, the daemon checks the code signature of the process again, as for an `[[allow]]` rule. On either mismatch the hook is refused and logged as `hook_refused` (reason `signature`), and the event waits for its owner. Code signed any other way (Apple Development, the Mac App Store, ad hoc) cannot be a `program` hook. Up to 1.0.2 the daemon started the program suspended and checked that process before letting it run. The kernel checks only the code it starts: a program that starts another in its place is refused when the second check sees the other one, and may be let through when the check comes too late, so a hook names the agent's own executable, never a wrapper. Apple code that starts other Apple code, as `/bin/sh` starts bash, passes. With SIP off macOS checks no launch requirement (AMFI skips launch constraints), so the check of the running process is the only one: a hook that exits before that check is refused (1.0.3, found on CI on 7 November 2026), and a program in the hook's place that starts the agent with arguments of its own before the check is not caught. A `program` hook that names its agent's `instructions` gets no files: the event, without its token, on stdin, and `/var/empty`, which belongs to root, as its working directory; its `stdin = "none"` from 1.0 still loads and changes nothing. One that names none gets what it got in 1.0, since blackice cannot know what it reads: the event in `BLACKICE_EVENT_FILE` too, in a private directory that is its working directory, with the notes as `notes.md`, and `stdin = "none"` keeps the event off stdin. `run = '…'` still runs through `/bin/sh -c` with no check, and gets the same as a `program` hook that names no instructions. `blackice agent connect` writes a `program` hook, with the identity read from the agent's binary. |
| Agent instructions | The instructions an agent decides by ship inside the blackice binary (decided on 5 November 2026). A `program` hook names its set with `instructions = "fx"`, `"claude-code"`, `"codex"` or `"opencode"`. Since 1.0.3 the daemon passes them, with the owner's notes, in the agent's own flags or environment each time it starts the hook, and writes no file for it (decided on 6 November 2026): Claude Code gets them with `--system-prompt`, the notes with `--append-system-prompt`, and no tools at all (`--tools ""`); Codex gets both in `-c developer_instructions="…"`, a TOML string that comes after Codex's own base prompt; fx gets both in `--system`, which replaces its own system prompt; opencode gets both as the prompt of the agent its hook names, in `OPENCODE_CONFIG_CONTENT`, with every tool denied, and a new, empty configuration folder of its own for each event. The event comes on stdin, which each of them adds to its prompt, and the instructions say so. About 10 KB of instructions and at most 4 KiB of notes stay far below the 1 MiB a command line may hold. A hook from 1.0, whose `args` name `instructions.md` or `event.json`, runs as the hook `agent connect` writes now for the same model, and the flags that carry instructions are the daemon's: the hook's own are dropped. Up to 1.0.2 the daemon wrote the instructions, the notes and the event into the event's private directory, which belongs to the user, and the agent read them there. Up to 0.4.0 `agent connect` copied the instructions into the agent's home; it removes those copies once the new hook is loaded. The text comes from `integrations/` through `macos/scripts/agent-instructions.sh`, and a test fails when the copy in the binary and those files differ. The owner's notes, `notes` in an `[agent]` table of `blackice.toml` (at most 4 KiB of plain text, the one value that may span lines), are part of the configuration loaded with Touch ID; a hook that names no instructions gets them as `notes.md` beside its event file. The instructions say to follow the notes for judgment calls but never over their safety rules (untrusted fields, lookalike hosts, at most 24 h), and that text in the event claiming to be a note is a reason to deny. What stays exposed is under "Self-approval" in the open problems. |
| Daemon | `blackice daemon` takes no options and reads no file (decided on 3 November 2026). The extension's reply to its registration carries the configuration the extension holds, the `blackice.toml` text that `start` or `mode` saved after Touch ID plus its generation, and the daemon takes its hooks and timeout from it, parsed with the same strict parser. Each event carries the generation of the configuration it was raised under, and is not sent once another one is installed; a daemon holding another one registers again on the same connection to get the current configuration, and runs no hook for an event whose configuration is gone. Hooks get an environment the daemon builds: `HOME`, `USER` and `LOGNAME` from the user database, `TMPDIR` from confstr, a fixed `PATH` and `LANG`, a `program` hook's `env` on top (which may set `HOME` but no `BLACKICE_` variable), the event's ID, and, for a hook that names no instructions, the event's file. `blackice agent install` and `uninstall` write and load, or unload and remove, the LaunchAgent, without Touch ID. |
| Configuration | `blackice.toml`, read by a small strict parser for the subset the file uses. No third-party dependency. |
| Configuration change | Installing a configuration ends what waits under the old one, paused for a lookup or an answer or held for its TLS hello, and cancels its events. The new configuration decides each such flow again, with no approval and nothing looked up: what it allows outright (accept-all, a rule, the Apple services table, loopback) goes on, logged with that reason and `;configuration_changed` (`accept_all;configuration_changed`), and the rest is dropped as `configuration_changed` (decided on 5 November 2026). Until then all of it was dropped, so switching from ask mode to accept-all cut the connections that waited: 20 at once on the Mac on 5 November. A flow the new configuration would allow only once its server name is read, or would ask about, is still dropped, and an answer taken under the old configuration still lets nothing through under the new one, even when it is applied after the change. Since 6 November 2026 that holds for an answer applied while the change is installed too. The answer takes its flows off the pending list, where the change cannot find them, so the check of their generation and each resume run with the installed configuration held in place (`ProviderSnapshotStore.withInstalled`): a change waits for them, or comes first and they are dropped as `configuration_changed`. Flows a finished host lookup releases are handled the same way. Until then a switch to block-all installed between the check and the resume let the approved flows through. |
| Start keeps a switch | `blackice mode` and the menu's Mode change the mode, and who answers in ask mode, in the configuration blackice holds, never in the file. `blackice start` keeps such a switch while the file still has what it had at the last start, and says so before Touch ID; once the file's own `mode` or `answers` changes, the file wins (decided on 5 November 2026). Until 1.0.0 only the `mode` line was compared, so a test file switched to accept-all left the owner's own ask-mode file in accept-all; since 1.0.0 another file, or any change to this one, wins. Until then every `start` loaded the file's mode, so an upgrade's `start` on 5 November 2026 switched a Mac from accept-all back to the file's ask mode and cut a running Claude Code session. The mode needs no record: a mode switch leaves the text's `mode` line as the file had it. A switch of `answers` rewrites that line, and leaves a comment on it with the file's own value (`answers = "codex"  # set by blackice mode; blackice.toml has "fx"`, or `has none` for a file that names no one), which later switches keep. Until 1.0.3 a second switch from a file that named no one wrote the first switch's answerer as the file's, so the next `start` no longer recognized the file and dropped both switches. A text switched by 0.4.2, with no comment, counts as switched when it differs from the file only in that line. An agent whose hook is gone from the file gives way to the file's `answers`. `agent connect`, and the first `start` right after its questions, load the file as written. |
| Menu bar | Blackice.app opened as an app, or `blackice menu`, runs in the menu bar (4 November 2026). It shows the state and answers by hand through the same code as the CLI, Touch ID included, and adds no privileged path. Starting, stopping, rules, agents and the daemon stay in the CLI. Quitting it leaves filtering as it was. |
| Install script pin | `site/lib/install.sh` pins the release's zip by SHA-256, on a `SHA256=` line beside `VERSION=`, and the zip must match it and the release's `.sha256` file before it is unpacked (decided on 6 November 2026). Until then the script trusted the `.sha256` file from the same release as the zip, which only caught a broken download. Each release sets both lines, from the `.sha256` file `macos/scripts/package.sh` wrote (it prints them), in the commit that moves the site to that release; the site's build fails without a SHA-256. `BLACKICE_ZIP`, for a build not published, checks the zip against the `.sha256` file beside it and says the pin is not used. |
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
   when their signature checks out. On 6 November 2026, with 0.4.5, both agents' `program` hooks answered real
   connections on the Mac ([P5-10](../evidence/P5-10-live-decisions-0.4.5-macos.md)).
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
   rules. On 4 November 2026 the one run against the sample event stopped at AI Gateway, whose team had no credits
   left (HTTP 502, `insufficient_funds`), with nothing on stdout. With credits, fx answered 26 events on the Mac in
   the 24 h before 6 November 12:40 UTC, and denied a `curl` to registry.npmjs.org in 6.6 s during P5-10.
   A second decider, written on 4 November 2026: Claude Code in print mode
   ([`integrations/claude-code/`](../integrations/claude-code/README.md)), with reading the event as its only tool,
   a sign-in of its own (its own `CLAUDE_CONFIG_DIR`, kept in the login keychain, so the hook keeps `HOME`) and a
   rule for `api.anthropic.com` and `platform.claude.com`. `blackice agent connect claude-code` writes its
   `program` hook as `connect fx` does, with `stdin = "none"`: `claude -p` adds stdin to its prompt, and the event
   should reach it only as the file it reads. (Since 1.0.3 the event comes on stdin and Claude Code has no tools at
   all; see "Agent instructions" under the decisions.) Under the daemon it answered 350 events on the Mac in the same 24 h,
   at a median of 3.8 s (P5-10). One agent answers at a time: since 0.4.2 each connected agent keeps
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
   On 6 November 2026, after P5-10 and the daemon's log showed the agents denying `curl` to the npm registry and a
   Homebrew `node` to Google Fonts, the four instructions say when to approve a runtime or fetch tool: for 1 h to 8 h,
   when it reaches a package registry, a source host or a public asset CDN, and anywhere else only when the owner's
   notes say so. Five eval cases cover it (24 to 28);
   Claude Code with Haiku decided the 28 as expected, at a median of 4.0 s, and with the old text denied `curl` to
   the npm registry. fx with Haiku decided 27, at a median of 4.9 s: on case 12 it exited 1 with no answer, so the
   connection would have been dropped at the deadline, and two runs of that case alone denied it.
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
   that. With the published 0.4.5 on 6 November 2026 all 29 checks passed, that one and the two `example.com` cases
   included ([P5-11](../evidence/P5-11-faults-0.4.5-macos.md)).
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
  - It can steer the hook into approving, its own connection included, through what the agent reads. Since 1.0.3
    (decided on 6 November 2026, as stage 1, with no stage 2 planned: no account of blackice's own, no daemon as
    root) a `program` hook that names its agent's `instructions` reads no file that blackice writes: the instructions and the notes come in its flags or
    environment, the event on stdin, and it runs in `/var/empty`. Up to 1.0.2 all three were files in the event's
    directory, which belongs to the user, and a program that watched the hooks' directory could rewrite them while
    the agent read them, so that the event showed a trusted app or the instructions said to approve. What each
    agent still loads from its own home:
    - Claude Code, its sign-in and state only: `--restricted` and `--safe-mode` ignore its settings, CLAUDE.md,
      skills and hooks, and the hook gives it no tools at all. Closed.
    - opencode 2.2.5 gets a new private configuration folder for each event (`XDG_CONFIG_HOME`), empty, so it
      loads no configuration, `AGENTS.md`, plugin or skill from a folder of the user's. That folder is inside the
      hooks' directory, which belongs to the user, so a program that watches it can still add one there while
      opencode starts: a race, as up to 1.0.2. Its sign-in and sessions stay in a database in its home, which also
      has a table of permissions; whether a row there could undo the hook's denials has not been checked.
    - Codex 0.166.0 still loads `AGENTS.md` and `AGENTS.override.md` from its `CODEX_HOME` as global instructions,
      and no flag turns that off; the list of its skills is off (`skills.include_instructions=false`). fx 0.0.16
      still loads its `AGENTS.md`, its skills, the skills of other agents in its `HOME` (`.claude/skills`,
      `.codex/skills`, `.agents/skills`, `.claw/skills`, `.config/opencode/skills`), and its rules and provider
      from its settings. For these two the daemon looks before it starts the hook and again once it exits: such a
      file that blackice did not put there (an `AGENTS.md`, a skill folder that Codex did not make, a skill for fx,
      or fx settings that are not the rules `agent connect` writes) means the hook does not start (`hook_refused`,
      reason `agent_home`), or that its answer does not count (`hook_no_answer`, reason `agent_home`). The event
      waits for its owner, and the menu says so for an hour. This only detects the change, and it loses to a
      program that adds the file after the first look and removes it before the second.
    The daemon then approves the app and host of its own copy of the event, which are the program's, for at most
    24 h. Not closed by stage 1: Codex's and fx's homes, which are only looked at; code loaded into a signed agent
    that allows it (Claude Code 2.1.318 and opencode 2.2.5 are signed with
    `com.apple.security.cs.disable-library-validation`, and opencode also with
    `allow-dyld-environment-variables`; the kernel checks the executable, not what it loads later), though the
    hook's environment comes from the configuration saved with Touch ID; `run` hooks, which have no check; an
    older signed build of the same agent, which meets the same launch requirement and may lack the flags above;
    and a Mac with SIP off, where the kernel checks no launch requirement and a program in the hook's place that
    starts the agent with arguments of its own before the daemon's check gets through.
    A hook that names no instructions still gets the event and the notes as files, as up to 1.0.2.
  - A `run` hook's program is not checked, so the program can be replaced with one that prints `approve 24h`.
    A `program` hook is checked by the kernel each time it starts, but a signed program can still be steered
    through what it loads from its home (above).
  - It can stop the daemon or keep it busy, and connections then wait and are denied at their timeout.
  - The daemon's memory holds the tokens of the events it is answering. The daemon is signed with the hardened
    runtime, so macOS refuses other programs of the user `task_for_pid` on it; that has not been tested on a Mac.
- **Daemon impersonation.** Any program of the user can still run `blackice daemon` and register in place of the
  LaunchAgent, but that copy runs the hooks of the configuration saved with Touch ID, in an environment it builds
  itself (see Daemon under the decisions), so it cannot run hooks of its own. Since 0.4.0 the registered daemon is
  also the only connection whose answers with a token the extension takes, and a copy that registers instead only
  sends what those hooks print. What remains: such a program can keep the LaunchAgent's daemon from getting events,
  by registering again and again or by stopping it, and connections then wait and are denied at their timeout. And
  the programs a hook runs still load files from their homes that any program of the user can change, such as
  Codex's `AGENTS.md` and fx's rules and skills (see "Self-approval"); their instructions and the event come from
  the daemon.
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
    November 2026; ask mode now asks about its address (see "Connections by address"). On the Mac on 6 November,
    `nc` to 1.1.1.1 port 80 raised an event for `1.1.1.1` and Claude Code denied it (P5-10). Off port 443
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
  "Remembered denials" under the decisions). On the Mac on 6 November, an app's connections after its deny were
  dropped as `denied;remembered` with no new event, and an approval replaced the denial (P5-10). What remains: no answer in time is not
  remembered, on purpose, so a broken or slow agent still costs one question per deadline, and a pair is asked
  about again 10 minutes after its deny.
- **Developer tools in an interpreter.** A CLI in Python or Node connects as its interpreter. On the Mac on 6
  November 2026, a mail CLI installed with uv connected as uv's ad hoc `python3.14`; the agent saw only that
  interpreter and the hosts (Google and Microsoft sign-in, IMAP on 993), and its instructions deny an interpreter
  reaching anything but developer infrastructure unless the owner's notes say otherwise. It denied all seven, each
  remembered for 10 minutes, and no rule could name ad hoc code. `approve` now takes several `--host` under one Touch
  ID, and `pending` and `status` show the remembered denials. Built for 1.0.3, as decided the same day: for an
  interpreter the event has `app.script`, the script its command line names (read by the extension with
  KERN_PROCARGS2, the audit token checked again after the read, only the script and never the other arguments),
  an untrusted field for the agent and the owner's notes and never an identity, since a process picks its own
  arguments; `pending` shows it too. And `[[allow]]` may name compiled ad hoc code by cdhash (`approve --save`
  writes such a rule), but never an interpreter (python, node, ruby, perl, bun, deno, the shells), whose lasting
  rule would cover every script it runs, a malicious dependency's included.
  The review of 7 November 2026 found the gap that was left: an approval named the interpreter and the host, so
  once the agent approved the AWS CLI's python to STS for a day, any script of that python reached STS for the day,
  and the owner's notes filtered only the first question. Since then an interpreter's approvals and denials are
  bound to its script: the agent's answer covers the script its event named (or no script, for `-c` and a
  REPL), each script waits on its own event, and an answer for one script releases no other script's
  connections. A person's answer covers every script unless it names one (`approve --script`, `deny --script`,
  and the menu's answers, which take the event's script when it is a full path); a person's answer for every
  script takes back each script's. The name still proves nothing, since a process picks its own arguments:
  binding only narrows what an answer covers, and a script that copies the AWS CLI's path gets its approval.
  On the Mac on 7 November, before the change, `aws` reached STS after an agent's approval and another script of
  the same python to S3 was denied, so the notes worked on the first question.
  On 10 November 2026 the read showed two faults, both from a process that writes a title over its own command line.
  node does it for npm (`process.title`, through libuv): KERN_PROCARGS2 gave `npm run wait` and four empty arguments,
  the filter took the first empty one for the script and joined it to the process's folder, so the event's script was
  the folder npm ran in and each folder was a scope of its own. Of node's 77 events with a script from 7 to 10
  November, 15 named a folder that still exists, and on 10 November the agent denied node registry.npmjs.org nine
  times, each for a script path under `/private/tmp`. The second: KERN_PROCARGS2 has nothing between the arguments and
  the environment, and a title as long as the arguments leaves no NUL to count them by. `node x.js` with a title of 20
  bytes read as `my-long-s` and then its first environment string, which the filter would have shown as the script;
  none of the 182 events with a script in the log holds one. Since 1.0.7 a command line whose second argument is
  empty, or only spaces (perl's `$0` pads with them), is a rewritten one: it has no script, and its event has
  `app.title`, which the agent reads, `pending` and the menu show, `events.jsonl` keeps as `app_title` and no decision
  reads. The title is the first three words of the first argument, none from the first option (`-`), assignment (`=`)
  or URL (`://`) on, cut to 64 bytes: a title is a command line again and can hold a token as arguments can (npm
  11.20.0 titles `npm run x -- --token …` as `npm run x --token …`), and an event goes to the agent and into the log.
  A secret among a title's first three words would still be shown. An argument with `=` before any `/` is never a
  script. The agent's answer for an event with a title covers the interpreter whenever no script can be read, whatever
  the title: after its approval of `npm run build` to the registry, `node -e` reaches the registry too. A person's
  `approve` with no `--script` covers every script the interpreter runs, as for any interpreter. What is not told
  apart: an interpreter started with an empty second argument reads as rewritten, and a title that is padded with
  something else than NUL or spaces is not seen as one. Two eval cases cover the title (34, npm to its registry, and
  35, a title that claims the owner's approval). On 10 November Claude Code with `haiku` decided the 37 cases as
  expected, and 36 of them in a second run, with the instructions that say the title is cut: case 16 (instructions
  in a host name, to deny) got no answer, which drops the connection at its deadline, and `deny` in five more tries.
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
- **Held flows with no socket.** On the Mac on 6 November 2026 (build 32, ask mode) the filter dropped 30 to 360 of
  Claude Code's connections per 10 minutes as `idle_before_hello`, each held the whole 120 s, while `netstat`, every
  5 s for 30 s, showed no socket to port 443 that had sent nothing: the sockets were gone, and the filter got no
  `handleOutboundDataComplete` for them. The connections Claude Code closes before writing, every few seconds, do get
  it and are logged `closed_before_hello`. About 70 such entries were held at once. Since then a new flow takes the
  place of a quiet one (see "One app's share"), so they no longer crowd out real connections, but `blackice report`
  still counts them as drops, and why macOS sends no callback is not established. A shorter quiet time is not the
  answer: 10 s broke Bun's spare connections (see "Waiting for the hello"). And a held flow whose hello has started
  is never displaced, so several apps that each keep 64 hellos started and unfinished, opening new ones every 10 s,
  can still fill the 256 places.
- **Limits of the host check.** The system resolver may answer blackice's lookup differently than it answered
  the app (round-robin, CDNs, split DNS), which shows as a mismatch: the connection is dropped, and ask mode asks
  only about a pair nothing names. On 10 November 2026 a mail CLI's approved connections to
  outlook.office365.com, on port 993, still mismatched after 1.0.4's second lookup: 6 of 155 with Tailscale's
  resolver and 15 of about 106 with the router's, up to 6 in a row; the CLI went on to the next address each time
  and no run failed. That host was then three CNAMEs of about 300, 300 and 45 s and eight addresses of 15 s under
  the last name, with eight others at each query, and the mismatches came in 10 of the 239 runs, 9 of them among
  the 34 in which the resolver sent three queries and 1 among the other 205. The log does not show the names in
  those queries; what fits is that the resolver asked for the chain's middle or last name, whose CNAME or
  addresses had expired, so the addresses came under that name and not the host's. The extension now follows
  the CNAMEs it read back from an address's name (see "Names from DNS answers"). With that and nothing else
  (build 42), the same listing every 10 s with Tailscale's resolver still failed on `address_mismatch` in 2 of
  180 runs (6 more failed while the network or its DNS was away), and the extension looked the host up itself
  30 times in the first 31 minutes. Two causes were found, and 1.0.7 fixes both. The resolver answers from a
  record for longer than its TTL, and the extension kept a name for the TTL: 10 of the 30 lookups came while the
  resolver followed a top CNAME past its TTL, and in one of them the CLI had the addresses under one name and
  the extension's lookup, 65 ms later, those under another. And the table of DNS flows was full after a burst
  (267 flows in the two minutes around a network coming back), so the answers after it went unread and the
  extension looked the host up itself five times in those two minutes; a test's 611 resolver flows in half a
  minute did the same. What stays: an app that got its addresses longer ago than the names are kept, a resolver that
  gives two askers different addresses for the same name when the extension does look a host up itself, and the
  first minutes after the extension starts, while the resolver still answers from records the extension never
  read.
  A CNAME is kept as long as its TTL says, up to a day and a quarter, and until then only `blackice stop` or a full
  table forgets it: not a change of network, and not a later answer that gives the name another target, since two
  resolvers of one Mac (a VPN's and the router's) can each hold their own. So a CNAME that one network's DNS server
  gave still passes the check on the next network, and a program that a rule or an approval already covers for that
  name could reach the CNAME's target under it. A shorter life would bring the mismatches back: of the 366 CNAME
  records in 25 minutes of this Mac's answers on 10 November 2026, 91 had a TTL over 5 minutes and 32 over an hour,
  the longest 12 hours. A program on the Mac can also fill the table of CNAMEs (4,096 targets) with long-lived
  chains of a domain it controls; the hosts whose CNAMEs it pushes out are then looked up by the extension again, as
  before 1.0.7.
  And a match
  proves only that the name resolves to that address now, not who controls the name. The server name is read only
  from TCP on port 443, and from the clear part of an Encrypted Client Hello: a rule or an approval for an ECH front
  end, such as `cloudflare-ech.com`, covers every site behind it. On another port, over UDP (QUIC) or in the HTTP
  `Host` header, an app with a rule for one
  host can still name another site behind the same address.
  Address entries in rules, and approvals of an address, check no name at all. On port 443 an address entry
  allows whatever server name the hello carries, so an entry for an address many sites share, such as a CDN's or a
  cloud provider's, covers every site behind it for that app. An approval of an address covers only connections
  to it with no name, and on port 443 only a hello with no server name.
- **A loop of dropped connections.** A dropped connection fails at once, and some programs then open the next one
  at once. On 10 November 2026, after a restart of the Mac (build 38, ask mode), identityservicesd did so to a
  link-local address on the `utun` interface of its link to the owner's iPhone, about 430 times a second, each
  dropped as `no_host`; in the 36 hours before, with that link already up, it had not tried once. Since 1.0.6 an
  app with 64 TCP connections dropped within 2 s has its next ones wait 2 s for their drop (`RepeatedDrops`), at
  most 64 at once per app and 256 in all, so a program that tries again after each failure tries once per 2 s for
  each connection it keeps open. After 30 s the app is counted afresh: a loop that goes on gets 64 drops at once
  every 30 s, and an app with one burst behind it does not go on waiting for each drop. Only TCP waits. A program
  does not wait for the drop of a UDP flow, and macOS makes `close()` wait 1 s on a socket whose flow is paused:
  build 39 delayed UDP too, and there `sendto()` returned at once and `close()` took 1.00 s. Past 64 drops within
  2 s an app's UDP drops get 8 log lines per 2 s, and `drops_not_logged` counts the rest; `blackice report`
  counts only the logged ones.
  The delay bounds the log, not always the work. The filter spends about 0.9 ms of processor time on a flow
  whatever it decides: on build 39, 12 programs each sending one datagram per new socket made 560 flows a second,
  and the filter used half a core with 88 of 4,474 logged. A UDP loop, a TCP loop with more than 64 connections at
  once, and one whose `connect()` macOS fails by itself still cost that (a program started from a terminal got
  "No route to host" from `connect()` to a link-local address within 0.1 ms, with its flow paused or dropped). The
  identityservicesd loop stopped when build 39 replaced build 38 and has not come back, so the delay was not seen
  on it. Since 1.0.7 every drop the filter decides for a connection is counted and delayed, wherever it comes: as
  the connection starts, once its TLS hello was read, which is where a connection to port 443 with no host name
  from the system is decided, after a lookup, and for a full table. 1.0.6 counted only a connection dropped as it
  started: on 10 November 2026 (build 40) node had 7,586 connections dropped as `denied;remembered` in
  55 minutes, after the agent denied it registry.npmjs.org, about 1,300 of them within one second three times,
  each logged and none delayed, and in the fault tests' bursts `nscurl` had 1,105 connections dropped at once as
  `lookup_capacity_app` (build 38) and 496 as `ask_capacity` (build 40). Not counted: a connection that already
  waited and is dropped by an answer, a timeout or a configuration change, and one refused a place among the
  held (`hold_capacity`, `hold_capacity_app`) or put out of it (`evicted_quiet`). The delay
  is counted per app, by its identity, so code signed ad hoc under many cdhashes is counted apart. Whether identityservicesd's link should pass in ask mode is not decided: it carries no host name, and
  while it is dropped whatever needs the iPhone does not work. Since 1.0.7 such a connection is asked about by
  its address, with no interface (see "Connections by address"), so the agent, the owner or a rule can decide it.
- **Before the owner logs in.** With FileVault on, the filter starts when the owner logs in, not when the Mac
  starts: on 10 November 2026 the Mac started at 07:59 and the filter at 08:31, at the login. Until then nothing
  is filtered, and only what macOS itself runs at the login window connects.
- **Lookups in a burst.** A connection whose host has no fresh answers waits for blackice's own lookup, at most
  1,024 at once and 256 per app; the next ones are dropped as `lookup_capacity` or `lookup_capacity_app`. In ask
  mode that includes connections nothing names. In the fault tests' burst after midnight on 10 November 2026
  (P5-20), before the share per app, about 300 connections were dropped that way in each of two runs; in one of
  them 8 were `curl`'s, and the test's `curl` to pypi.org, which a rule allows, failed. The share keeps one app's
  burst from taking the other apps' places, but while lookups are slow that app's own connections past its 256 are
  still dropped.
- **Hook limits.** The limit of 4 hooks at once, at most 256 hooks waiting for a slot, the 10 s a waiting hook needs
  left to start (or the whole timeout, when that is shorter), the 2 s grace period, the 4 KiB of stderr kept per
  hook and the 64 KiB of stdout read for its answer are first guesses, set in code rather than in `blackice.toml`.
- **Log rotation.** The event log only grows. Rotation, or leaving it to newsyslog, is not decided.
- **Installation.** No dialog per connection, but macOS asks once to allow the extension in System Settings, unless
  the Mac is managed with an MDM profile.
