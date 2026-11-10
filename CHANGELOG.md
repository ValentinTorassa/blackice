# Changelog

## Unreleased

New:
- `blackice deny --all` forgets every approval, with one Touch ID. What waits keeps waiting, remembered denials
  stay, and connections already let through go on. Since 1.0.6 approvals outlast a stop, an upgrade and a restart
  of the Mac, and `blackice deny` takes back one app and host at a time: nothing cleared them all.

Fixed:
- Every connection the filter drops is counted, and delayed once its app has had 64 dropped within 2 s, wherever
  it is dropped. 1.0.6 counted only a connection dropped as it started: one dropped once its TLS hello was read,
  after a lookup, or for a full table was dropped at once. On 10 November, on 1.0.6, node had 7,586 connections
  dropped as `denied;remembered` in 55 minutes after the agent denied it registry.npmjs.org, about 1,300 of them
  within one second three times, and none was delayed.
- A host that is an alias of the name its address came under passes the address check. The filter reads the
  system resolver's answers and keeps, for each address, the name the answer was for. The resolver keeps each
  CNAME of a chain for its own TTL and, once the addresses at the end have expired, asks only for the name they
  belong to, so that answer names the end of the chain and not the host the app asked for. The filter then looked
  the host up itself and could get other addresses. On 10 November outlook.office365.com was three CNAMEs of 300,
  300 and 45 s and eight addresses of 15 s, with eight others at each query: a mail CLI's approved connections
  there were dropped as `address_mismatch` in 10 of 239 runs, 9 of them among the 34 runs in which the resolver
  sent three queries, and each time the CLI got through on a later address. The filter now keeps the CNAMEs it
  reads, each for its TTL and at most a day, and follows them back from an address's name.
- A connection to a link-local IPv6 address can be asked about. The filter read the address from text that names
  no interface, and such an address could be any host on any link, so the connection was dropped as `no_host`
  with no event: on 10 November identityservicesd's connections to a peer on a `utun` interface all were. From
  macOS 15 the filter reads the interface from the flow's own endpoint.

Changed:
- An approval for a link-local address is not saved to the approvals file: its host names the interface by its
  number, which may be another interface's after a restart. It lasts until the filter's process ends, or its time.

## 1.0.6 (10 November 2026)

Fixed:
- An app that opens its next connection as soon as one is dropped no longer fills the log, and a loop of TCP
  connections is slowed. Once an app has had 64 TCP connections dropped within 2 s, its next ones that would be
  dropped wait 2 s first, at most 64 at a time, and after 30 s the app is counted afresh. UDP flows never wait:
  past the same count they get 8 log lines per 2 s. Drops with no log line are counted (`drops_not_logged`). On
  10 November, after a restart, identityservicesd tried a link-local peer about 430 times a second: the filter
  used half a core, other connections were slow to start, and the system log dropped most of the filter's lines,
  so `blackice report` counted 6,122 connections where there had been more than 200,000. 1.0.5 and earlier have
  the fault. A loop of UDP flows, or of more than 64 TCP connections at once, still costs the filter its work
  on each flow. Only connections dropped as they start are counted and delayed: one dropped once its TLS hello
  was read, or after a lookup, is dropped at once as before.

Changed:
- Approvals outlast `blackice stop`, an upgrade and a restart of the Mac. The filter saves them to a file only root
  can read or write, and each comes back with what it had left, less the time gone by. Until now they lived only in
  the filter's memory, so each stop or upgrade cleared them and the agent was asked again about apps and hosts it
  had approved. Remembered denials are still forgotten at a stop.
- One app takes at most 256 of the 1,024 places for connections waiting for blackice's lookup of their host
  (`lookup_capacity_app`). On 10 November one app's burst took them all while lookups were slow, and another app's
  connection that a rule allowed was dropped as `lookup_capacity`.

## 1.0.5 (9 November 2026)

Changed:
- In ask mode a connection that a rule, the Apple services table or an approval allows by name, but whose address
  is not among the host's answers even after a fresh lookup, is dropped at once as `address_mismatch`, as in
  block-all. Until now it raised an event, and the agent's approval could not let it through: in 18 hours on one
  Mac, 100 such events, every one approved and its connection dropped anyway, each holding one of the 4 hook slots
  for about 3 s. An app and host that nothing allows yet are still asked about, since the approval counts from the
  app's next connection.

## 1.0.4 (8 November 2026)

Fixed:
- A hook the Mac slept through is killed when the Mac wakes past its event's deadline. Until now its timeout counted
  only time awake, so it ran on for up to its whole timeout after its event had timed out, held a slot, and its answer
  was refused: on 8 November four of them held all 4 slots for 12 minutes after a sleep, and the next 4 events got no
  hook.
- A host's answers 2 s old or older that miss the address a connection goes to are looked up again before they
  count as a mismatch. Until now answers were kept 30 s, and a CDN that rotates its addresses every few seconds
  missed: about 2 % of a mail CLI's approved connections to outlook.office365.com were dropped as
  `approved;address_mismatch`, each after an event the agent approved again.

## 1.0.3 (7 November 2026)

New:
- An `[[allow]]` rule can name ad hoc signed code, such as Homebrew's `gh`, by `cdhash = "…"` in place of `app` and
  `team`. It covers that one build, so after an upgrade ask mode asks again. It never counts for an interpreter (python,
  node, the shells and others), whose connections are decided as without it (`;interpreter`). Until now ad hoc code
  could only be approved, for at most 24 hours.
- `blackice approve` takes `--host` up to 16 times: one app's hosts under one Touch ID, whose dialog names them all.
  Until now each host took its own command and Touch ID, seven for a mail CLI that signs in to Google and Microsoft.
- `blackice approve --save` also writes a lasting `[[allow]]` rule for the app and hosts in `blackice.toml`, which counts
  from the next `start`. Until now an approval was the only way to let ad hoc code through, for at most 24 hours.
- For an interpreter (python, node, a shell…), the event, `pending` and the event log (`app_script`) show the script it
  runs, as `app.script`, so the agent and your notes can tell one tool from another. Until now every uv or npm CLI
  looked the same: its interpreter.
- An interpreter's approvals and denials are bound to its script: the agent's answer covers the script its event
  named, each script waits on its own event, and `pending` says which script an approval covers. `approve --script`
  and `deny --script` name one script, and the menu's answers take the event's; without it your answer covers them
  all. Until now an approval of an interpreter let every script it runs reach that host: once the agent approved the
  AWS CLI's python to STS for a day, any script of that python reached STS for the day.

Changed:
- blackice needs macOS 14.4 or later: the daemon starts `program` hooks with a launch requirement, so macOS runs one
  only when its signature names the hook's `app` and `team`, with a Developer ID (or, with no `team`, Apple's own
  code). Until now the daemon started it suspended and checked it before letting it run, and a program that stopped
  the hook and let it run first got past the check. With SIP off macOS does not check launch requirements, and a
  hook that exits before the daemon can read its code is refused.
- A hook that names an agent's `instructions` gets no files: the instructions and the owner's notes come on its
  command line (Claude Code, Codex, fx) or in its environment (opencode), the event on stdin, and it runs in
  `/var/empty`. Claude Code runs with no tools at all. A hook from 1.0 runs the same way. Until now all three were
  files in a folder any program running as you could change while the agent read them.
- The daemon looks in Codex's and fx's homes before it starts their hook and once it exits. A file there that they
  would load as instructions, such as `AGENTS.md` or a skill, keeps the hook from starting, or voids its answer
  (`agent_home` in the log and the menu), and the connection waits for you. Until now nothing looked. This only
  detects the file, and can miss one added and removed while the hook runs.

Fixed:
- When nobody answers Touch ID within 2 minutes, the command says so ("No answer to Touch ID within 2 minutes"), and
  a finger that does not match says that. Until now each said "Touch ID was cancelled", as if Cancel had been pressed.
- `pending` lists the apps and hosts denied a moment ago first, each app's hosts with one `blackice approve` line,
  and `status` counts them. Until now `pending` opened with "Nothing waiting" while a remembered denial dropped the
  app's connections without an event, so there seemed to be nothing to approve.
- An approval that lands while the configuration changes no longer lets its connections through under the new one.
  Until now a switch to block-all at that moment missed them, and the old approval let them go.
- One app holds at most 64 of the 256 connections waiting for their TLS hello, and a new one replaces the oldest
  that has sent nothing (`evicted_quiet`). Until now one app could fill them all, and other apps' TLS connections
  were dropped as `hold_capacity`.
- In ask mode one app takes at most 64 of the 256 events (`ask_capacity_app`). Until now one app could fill the
  table, and other apps' connections were dropped with no event.
- A second switch of who answers, from a file that names no one, keeps the first one's record. Until now the next
  `start` dropped both switches.
- `agent connect` saves `blackice.toml` under a lock, and stops a sign-in check that gives no answer in 30 s. Until
  now two runs could overwrite each other, and a stalled check left the Mac in accept-all.
- `npx blackice install` checks `--force` and the installed build again just before replacing the app. Until now
  another install meanwhile, even of a newer build, was replaced.
- `pending`, `report` and the menu call code known only by its cdhash `cdhash 8fbec897`, not ad hoc: since 1.0.1
  that includes signed programs in `~/Documents` or `~/Downloads`.
- `report` names the capacity drops in words.

## 1.0.2 (6 November 2026)

Fixed:
- Approvals, remembered denials and connections waiting for an answer count the time the Mac spends asleep. Until now
  the filter's clock stopped during sleep, so an approval for 1 hour was still valid after 2 hours asleep.
- A program whose path has a line break or another control character no longer keeps `blackice pending` and the menu
  from listing what waits: its event leaves the path out. Until now one such event made the whole list unreadable
  until it expired.
- `blackice report` escapes the reasons in its estimate for ask mode, as it already did app names, so a program that
  writes to the filter's log cannot put terminal control sequences in the report.
- The install script checks the signature of a Blackice.app already installed at the same version before it writes
  the `blackice` command, and stops when it is not signed with the Developer ID of team M294LK997M. Until now it
  trusted the version in the app's Info.plist.

Upgrading from 1.0.1: `brew upgrade --cask blackice`, or the install script with `--force`, then `blackice start`.

## 1.0.1 (6 November 2026)

Fixed:
- A program that runs from a folder macOS keeps the filter from reading (`~/Documents`, `~/Desktop`, `~/Downloads`,
  iCloud Drive, removable and network volumes) is named by the cdhash of the code the kernel loaded, as ad hoc code is,
  so ask mode asks about it. Until now the filter could not check its signature and dropped its connections as
  `unknown_identity`, with no question: a tool a project keeps in `node_modules`, such as the Codex that deepsec runs,
  could not connect in ask mode. A rule still cannot name such a program, and block-all still drops it.

Upgrading from 1.0.0: `brew upgrade --cask blackice`, or the install script with `--force`, then `blackice start`.

## 1.0.0 (6 November 2026)

The first stable release: a `blackice.toml` that works in 1.0 keeps working in every 1.x. It has run on one Mac,
with macOS 27.0.1; macOS 14 and 15 are not tested yet.

Changed:
- The first `blackice start` ticks the VPN tunnels macOS has activated, even when they are off, and the common apps
  running (browsers, chat and video-call apps), matched by signing identifier and Team ID. Proxy extensions, such as
  a VPN's split tunneling, and the other apps are listed unticked.
- The agents read the owner's notes as additions: only a note that says to deny something narrows what their
  instructions approve.
- Toolchain folders (`~/.local/bin`, uv's Pythons, `~/.cargo/bin`, nvm, pyenv and others) count as ordinary places to
  run from, and GitHub Actions' log storage joins the source hosts developer tools may reach.
- The install script pins the zip's SHA-256 and checks the Developer ID requirement of team M294LK997M. The install
  guide says how to read the script first, or run the tag's copy from GitHub.

Fixed:
- A picked app's rule covers its helpers signed by the same team. Until now Chrome's and Slack's connections, which
  come from their helpers, still waited in ask mode.
- `blackice report` says when macOS dropped the filter's log lines, instead of printing low counts.

Upgrading from 0.4.7: `brew upgrade --cask blackice`, or the install script with `--force`, then `blackice start`.

## 0.4.7 (6 November 2026)

`blackice start` loads the file's mode again after a test file, and the agents let developer tools reach developer
infrastructure.

Changed:
- The agents' instructions say when to approve a developer tool. `node`, `python3`, `curl`, `git` and the
  package managers and builds they run are approved, for 1 to 8 hours, when they reach a package registry, a source
  host or a public asset CDN such as Google Fonts, and still denied anywhere else. Until now Claude Code and fx
  denied `curl` to the npm registry. Agents already connected use the new text after the upgrade, with nothing to
  run: the daemon writes the instructions for each event.

Fixed:
- `blackice start` keeps a mode or answerer switched with `blackice mode` or the menu only while the file is the one
  started then, unchanged. Until now it compared only the file's `mode` line, so starting another file, or the same
  file with a rule more, in the same mode kept the switch: after a test file was switched to accept-all, the owner's
  own ask-mode file started in accept-all.

Upgrading from 0.4.6: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice start`.
Nothing else changes.

## 0.4.6 (6 November 2026)

`blackice start` opens blackice in the menu bar, and the site and docs are a third as long.

Changed:
- Each `start` that turns blackice on opens the menu bar app when it is not running, as it already did for a menu
  from before an upgrade. The first `start` asks only whether it also opens at each login.
- The site keeps four pages: Introduction (with How it works), Install, Configuration and CLI. The changelog page
  points here. The install script prints five lines.

Upgrading from 0.4.5: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice start`.
Nothing else changes.

## 0.4.5 (5 November 2026)

A quieter command line: each command says what happened in a line or two.

Changed:
- `blackice help` fits on one screen. `blackice help COMMAND`, or `COMMAND --help`, has that command's options,
  and a usage error ends with the command's usage line.
- `start` prints the Touch ID line and `✓ blackice is on in ask mode, Claude Code answers`; `mode` prints `✓ Now
  in …` the same way. `stop` ends with `✓ blackice is off`.
- `status` is one line for the mode, then a row each for who answers, what waits, the rules, the approvals and
  the timeout, and the daemon only when hooks need it and it is not running.
- `pending` shows each waiting connection as `app → host:port`, with the `blackice approve` line that lets it
  through, and the approvals and denials in columns. Time left reads `45s`, `12m` or `23h 55m`, as do the
  answers of `approve` and `deny`. An app from outside Apple keeps its team, as in
  `com.tinyspeck.slackmacgap (BQR82RBBHL)`, since any developer can pick any signing identifier.
- `agent connect` is a title and a check per step: the agent found, signed in, its limits, the test, the rule,
  the hook, the file saved; then the start's own lines. The first `start` does the same under `4 · Connect fx`.
- `report` starts with a total (`Last 1h: 10271 connections, 1244 dropped, 124 asked about`) and says each drop
  reason in words, such as "sent nothing for 2 minutes" for `idle_before_hello`.
- The first `start`'s lists stay on screen as one line each, the question and what was picked.
- `agent install` and `uninstall`, and `menu --login`, say what they did in one line.

Upgrading from 0.4.4: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice
start`. Nothing else changes.

## 0.4.4 (5 November 2026)

A shorter menu: Codex and opencode show in Mode once they are connected.

Changed:
- For now the menu's Mode and the first `start`'s list leave Codex and opencode out: Mode lists Accept All, Ask
  with fx, Claude Code and you, and Block All, and shows Codex or opencode once it is connected. Nothing else
  changes: `blackice agent connect codex|opencode` sets them up and `blackice mode ask --agent` switches to them.

Upgrading from 0.4.3: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice
start`. Nothing else changes.

## 0.4.3 (5 November 2026)

opencode can be the agent, `blackice start` keeps the mode and the answerer you switched to, and a connection
that waits before its first byte is no longer cut after 10 s.

New:
- opencode can be the agent: `blackice agent connect opencode` asks which provider it decides with (OpenAI, Z.AI
  Coding Plan, OpenCode Go, MiniMax Token Plan, OpenRouter or Anthropic), signs it in to that provider in a home of
  its own, and adds a rule for that provider's hosts only. `--model PROVIDER/MODEL` skips the list. Its hook gives it
  the read tool and no other, in the event's directory, with blackice's instructions as its whole prompt, and no
  configuration, plugin or skill from a folder of yours. It is in the first start's list and in the menu's Mode.
  On 5 November 2026 it decided the 23 eval cases as expected with `openai/gpt-6-luna` on a ChatGPT plan, and 22
  with Z.AI's `glm-5.3-flash`, which approved Slack on port 6667, so OpenAI is first in the list.

Changed:
- `blackice start` keeps a mode, and who answers in ask mode, switched with `blackice mode` or the menu since the last
  start, as long as the file still has what it had then, and says so before Touch ID. A change in the file wins, and
  `agent connect` loads the file it wrote. Until now every `start`, an upgrade's included, went back to the file's
  mode: an upgrade switched a Mac in accept-all back to the file's ask mode.

Fixed:
- A connection held for its TLS hello in ask or block-all is no longer cut 10 s after it opens when the app has
  written nothing yet: it may stay quiet for 2 minutes, and has 10 s from its first byte for the hello. fx and
  Claude Code lost 175 connections in two days to the old deadline. A quiet one dropped at 2 minutes is logged
  `idle_before_hello`, apart from `server_name_timeout`.

Upgrading from 0.4.2: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice
start`, which keeps a mode or an answerer you switched to with 0.4.2's menu. The agents' hooks need nothing;
`blackice agent connect opencode` sets opencode up.

## 0.4.2 (5 November 2026)

You choose who answers in ask mode from a smaller menu, an app updated while it runs keeps its connections, an
upgrade loads the new configuration, and fx's hook reads less.

New:
- You choose who answers in ask mode, from the menu or the CLI. The menu's Mode lists Accept All, then Ask with
  each agent (fx, Claude Code, Codex; one that is not connected is greyed out with the command that connects it),
  Ask: You (Manual), and Block All, with a check mark on the one in force; choosing one takes Touch ID.
  `blackice mode ask --agent fx|claude-code|codex|you` does the same. Asked for by a tester on 5 November 2026.
- Connected agents keep their hooks side by side: `answers` in `[agent]` names the one whose hook runs (or `you`,
  for none), and hooks without `instructions` run either way. `agent connect` adds its agent's hook beside the
  others and sets `answers` to it, where it used to replace the other agent's hook. Switching with `mode --agent` or
  the menu changes the configuration blackice holds and not the file, as `blackice mode` does. `blackice status`
  says who answers when there is a choice. An agent hook that names no `instructions` (from 0.3 or 0.4.0) is still
  replaced or removed by `agent connect`, since it would run whoever `answers` names.

Changed:
- A smaller menu, asked for by the same tester. Recent decisions take one line, the latest with how long ago, and the
  last five in its submenu. Open blackice.toml, Show Event Log in Finder, Documentation and Open at Login are gone
  (opening at login is `blackice menu --login on|off`, which the first `start` offers); the version is at the bottom,
  above Quit Menu; the hooks line and "Nothing waits" show only when they say something. The install script and the npm
  package say only what to run next.
- fx's hook replaces fx's own system prompt, written for coding, with two sentences (`fx ask --system`). Each
  decision reads about 3,700 fewer tokens, about 17%, with the same answers in the cases tried. Run `blackice agent
  connect fx` again to get it; the hook from 0.4.1 keeps working as it is.
- In ask and block-all, macOS's encrypted DNS (DNS over HTTPS or TLS from `com.apple.mDNSResponder`, on port 443 or
  853) is dropped at once as `encrypted_dns`, where it used to be asked about or dropped as `no_host`. macOS then
  uses plain DNS, whose answers blackice reads to name the addresses apps connect to. A rule for
  `com.apple.mDNSResponder` lets an encrypted resolver through.
- A connection the app closed before it sent a byte is logged as `closed_before_hello`, where it was `tls_unparsed`,
  and `blackice report` lists those apart from the drops: nothing was cut. Claude Code opens two connections at once
  (IPv6 and IPv4), uses the first one up and closes the other, and in ask mode its report read as 7 drops.

Fixed:
- An app updated while it runs keeps its identity. When an update removed the program file of a running app, as
  Homebrew does with the old version, macOS could no longer check its signature, and ask and block-all dropped all
  its connections as `unknown_identity`: on 5 November 2026 that cut off a running Claude Code the minute Homebrew
  upgraded it. blackice now keeps the identity it checked while the file was there, for as long as that process
  runs, also across an upgrade or a stop and start of blackice in the same boot. When its cache of identities fills
  up, it forgets the processes that ended, where it used to forget them all.
- `blackice start` after an upgrade loads the new configuration into the new extension. macOS starts the new build
  with the configuration saved before, and a save made while it starts could miss it: on 5 November 2026 the 0.4.1
  build came up with the old configuration and `start` said the filter "did not load the configuration just saved".
  `start` now waits for the new build to answer before it saves, and if the new build still has the old configuration,
  it turns the filter off and on once.

Upgrading from 0.4.1: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice
start`. Then run `blackice agent connect fx` again for its shorter prompt; the other agents' hooks need nothing.

## 0.4.1 (5 November 2026)

Codex can be the agent, the agent reads your notes, its instructions ship inside blackice, ask mode asks
less and costs less, and the filter's log names the app.

New:
- `blackice agent connect codex` sets Codex up as the agent, signed in with a ChatGPT plan: a `CODEX_HOME` of its
  own with its sign-in (`codex login`), a test on a sample connection, a signed program hook (`codex exec`, model
  `gpt-6-luna`) and a rule for `chatgpt.com` and `auth.openai.com`. Its hook ignores your Codex configuration,
  rules, hooks, plugins and web search, replaces Codex's base prompt with blackice's instructions, and lets its
  commands read only the event's directory and the system's own files, with no writes and no network; not
  `--sandbox read-only`, which reads your whole home. The first `blackice start` offers it next to fx and Claude
  Code. `integrations/eval/run.sh --agent codex` runs it over the 23 cases: on 5 November 2026 `gpt-6-luna` and
  `gpt-6.1-sol` both decided all 23 as expected, in 4.6 and 6.6 s at the median.
- Notes for the agent: `notes` in an `[agent]` table of `blackice.toml`, up to 4 KiB of plain text over several
  lines (`"""…"""` or `'''…'''`, the only multi-line strings the file takes), such as the tools you use for work
  or hosts you never want reached. The daemon writes them as `notes.md` beside the event, and the instructions
  have the agent follow them for judgment calls, never over their safety rules. They change only with Touch ID,
  like the rest of the file. `[allow]` and `[hook]` with single brackets now say they need double ones.
- The filter's log lines name the app in the clear, after the verdict and reason: `flow drop timeout
  app=ABCDE12345/com.example.tool`, `apple/…` for Apple's own code, `cdhash/…` for ad hoc code. The host and the
  rest stay private. Until now nobody could tell from the log which apps lost connections.
- In accept-all, each of those lines also says what ask mode would have done with the same rules, worked out by the
  same code: `would=ask`, `would=rule_line_3`, `would=apple_service;server_name`, `would=read_server_name`,
  `would=drop:no_host`. Connections still go through at once; nothing is held, looked up or asked.
- `blackice report [--last 1h]` sums the filter's log up: drops by reason and app, connections paused to ask by app,
  and in accept-all what ask mode would have asked about, by app. It reads `log show` and needs no Touch ID.
- The menu has Stop Filtering, with Touch ID, as `blackice stop` does. Until now its only way out was Quit Menu,
  which leaves the filter running.

Changed:
- Ask mode costs less. `agent connect` writes a small model into the hook: fx asks for Claude Haiku 5.5
  (`anthropic/claude-haiku-5.5`), whatever its settings name, so AI Gateway bills a hundredth of what Claude Fable
  5.1 costs; Claude Code uses `haiku` in place of `sonnet`. `agent connect … --model NAME` picks another, and
  connecting again with another model replaces the hook's. The instructions approve clearly ordinary developer and
  vendor traffic for 8 to 24 hours, so the same app and host come back once a day at most, and anything less plain
  for 10 minutes to an hour; up to 0.4.0 every approval was 10 minutes to an hour. With Claude Code on 5 November
  2026, `haiku` and `sonnet` both decided the 23 eval cases as expected, `haiku` in 4.2 s at the median and
  `sonnet` in 5.1 s. Run `agent connect` again to get the new model.
- The agents' instructions ship inside blackice. A `program` hook names them with `instructions = "fx"` or
  `"claude-code"`, and the daemon writes them into the event's private directory before the agent starts: fx's
  skill as `skills/blackice/SKILL.md`, Claude Code's system prompt as `instructions.md`. Up to 0.4.0 they were
  files in the agent's home, `~/.config/blackice/agent`, that any program running as you could rewrite to approve
  everything. `agent connect` writes the new key and removes those copies once the new hook is loaded.
- A deny is remembered for 10 minutes, from a hook, `blackice deny` or the menu: in ask mode the app's new
  connections to that host are dropped at once as `denied;remembered`, with no event and no hook. On the Mac one
  ad hoc binary was asked about 52 times in two days, mostly denied. No answer in time is not remembered. An
  approval replaces the denial, a configuration change forgets it, and `blackice pending` lists them under "Denied
  recently".
- 34 more macOS services pass without a rule, each seen waiting in ask mode on the Mac on 3 and 4 November while
  reaching only Apple's domains: Find My, iCloud settings, storage and Keychain escrow, Apple Media Services and
  Music's library and artwork, Siri and Spotlight suggestions, Private Cloud Compute's gateway, key transparency,
  call history sync, Safari's Safe Browsing service (not Safari), aerial wallpapers, Help, content cache discovery,
  diagnostics submission and others. Most get only the hosts they reached; those on an iCloud host named after the
  account's partition (`p404-…`) get `*.icloud.com`. accountsd, which signs in to other providers' accounts, stays
  out.

Fixed:
- A configuration change lets the connections that wait go on when the new configuration allows them outright
  (accept-all, a rule, the Apple services table, loopback), logged as `accept_all;configuration_changed` and the
  like. Until now all of them were dropped (`configuration_changed`), so switching from ask mode to accept-all cut
  what waited. The rest is still dropped, and an answer given under the old configuration still lets nothing
  through under the new one.
- `agent connect fx` works beside a development build of fx. When the first fx on PATH is unsigned or ad hoc
  signed, as `fx upgrade --channel dev` builds are, it uses a signed fx further on PATH, or offers to install fx's
  release for blackice only, in `~/.config/blackice/agent/bin`, leaving yours and your PATH as they are. Until now it
  stopped at "Find fx": no rule can name such a build.
- The menu bar app no longer stays "Not reachable" after an upgrade. Each build of the extension listens on an
  XPC service of its own, and the menu from before the upgrade kept asking the old one. Now the menu opens the new
  Blackice.app itself once the app is replaced, and quits once it is removed; `blackice start` closes and reopens a
  menu left from another build, such as the 0.4.0 one, which cannot tell.

Upgrading from 0.4.0: `brew upgrade --cask blackice` or the install script with `--force`, then `blackice
start`. Then run `blackice agent connect fx` (or `claude-code`, or `codex`) again to get the small model and the
instructions inside blackice; until then the hook keeps 0.4.0's model and its instruction files.

## 0.4.0 (5 November 2026)

Hooks answer on their output, Claude Code can be the agent, blackice sits in the menu bar, and upgrades no longer
need a restart.

Changes that break 0.3 hooks:
- A hook answers with the last line of its output: `approve 10m`, `approve 1h` (up to `24h`) or `deny`, and exit
  status 0. The daemon reads it and passes the answer on itself. The event's token no longer leaves the daemon and
  the network extension: hooks never see it, and `blackice approve` and `deny` no longer take `--token` (they always
  ask for Touch ID). Any program of the user could read the token from the hook's event file or from the process
  list and approve its own connection.
- A hook can be a signed program: `program`, `app`, `team`, `args`, `env` and `stdin` in `[[hook]]`. The daemon
  starts it suspended, checks the signature of that process, and runs it only if it matches (`hook_refused`
  otherwise), so replacing the agent's binary keeps it from running. `run` still works, without that check.
- The event log has `hook_answer`, `hook_no_answer` (with the reason), `answer_refused` and `hook_refused`.

New:
- `blackice agent connect claude-code` sets Claude Code up as the agent: its own configuration directory and
  sign-in, reading the event as its only tool, a test on a sample connection, a signed program hook and its rule.
  The first `blackice start` offers fx, Claude Code or you. Connecting one agent replaces the other's hook.
  `integrations/eval/run.sh --agent fx|claude-code` runs either over the same 20 cases.
- The menu bar: the blackice mark, dimmed when nothing is filtered, with the number of waiting connections. Its menu
  shows the mode, each waiting connection with Allow for 10 Minutes, Allow for 1 Hour and Deny (Touch ID), the last
  verdicts and who gave them, a Mode submenu and Open at Login. `blackice menu` runs it, and so does opening
  Blackice.app. Quitting it leaves the filter running.
- Loopback (127.0.0.0/8, ::1) passes in every mode; `loopback = false` turns that off.
- In ask mode a TCP connection with no host name is asked about by its address instead of being dropped, and
  `blackice approve --host` takes an address. UDP with no name, multicast and broadcast are still dropped without
  an event.
- `hosts` in `[[allow]]` takes addresses and ranges: `["100.64.0.0/10", "10.0.0.5", "fd7a:115c:a1e0::/48"]`.

Fixed:
- Upgrades in place: every build used the same XPC service name, and the replaced extension held it for up to 5 s,
  so the new one often could not be reached until the Mac restarted. Each build now has its own name.
- On port 443, a connection the system names is held to the TLS server name it sends, as DNS-named ones were, so
  an app cannot name an allowed host and reach another site on the same address. A hello with Encrypted Client
  Hello is judged on its outer name (reasons end in `;ech`); a rule for a front-end name covers what sits behind it.
- An answer given under one configuration no longer lets a connection through after a switch to another one.
- Link-local IPv6 addresses keep their interface.
- `start` and `mode` report success only once the filter names the configuration they saved (exit 70 or 69
  otherwise), and `status` says when the filter holds another one.
- `agent connect` never leaves accept-all behind: when it fails or you press Control-C, it switches back. A first
  `start` whose agent setup fails stays in accept-all, filtering nothing as before, and says so. Edits made to
  `blackice.toml` during the setup are kept.
- Message and configuration size limits agree on both sides; the daemon no longer keeps a finished task per event;
  names that apps choose are escaped in the terminal.
- The install script and the npm package check that the app is the version asked for, keep the installed app if a
  replacement fails, and refuse a lower build.
- A dropped connection shows in the app as "Bad file descriptor"; the guide says so.

Upgrading from 0.3.2: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`, then `blackice
start`. No restart should be needed; if `start` exits with 75, restart the Mac and run `blackice start` again. Then
run `blackice agent connect fx` (or `claude-code`) again: a 0.3 hook still runs `blackice approve --token`, which
0.4.0 refuses, so until then ask mode denies what waits.

## 0.3.2 (4 November 2026)

Fewer connections waiting in ask mode.

- The first `blackice start`'s list of apps to trust shows the system extensions running now, such as a VPN
  client's network extension. They run from `/Library/SystemExtensions`, so the list left them out, and on the Mac
  Tailscale's sent 316 of the 905 events of the 0.3.0 runs and 227 of the 351 that got no hook.
- Four more macOS services pass without a rule, each seen waiting in those runs: codesign's timestamp service, to
  timestamp.apple.com only (in ask mode a signature could end up with no timestamp), iCloud contacts, Apple Media
  Services and the app categories Screen Time uses.
- A connection that arrives while 4 hooks run waits for a free one instead of getting no hook, and the waiting
  connections take turns between apps, so one app's burst no longer crowds out the rest. One is given up when less
  than 10 s of its time is left, when it ends while it waits, or when 256 already wait. The event log says so:
  `hook_queued`, `waited_ms`, and `hook_dropped` with `deadline_near`, `event_ended` or `queue_full` in place of
  `concurrency_limit`.

Upgrading from 0.3.1: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`, then `blackice
start`, then restart the Mac. On macOS 27 an extension upgraded in place cannot be reached until the Mac restarts.
Then run `blackice agent uninstall` and `blackice agent install`, so that the daemon runs the new binary: the queue
is in the daemon. If you already have a configuration, the first start's list does not run again; to trust a VPN
client, add a rule with `hosts = ["*"]` for its network extension (`systemextensionsctl list` names it).

## 0.3.1 (4 November 2026)

Pick several apps to trust with Enter.

- In the first `blackice start`'s list of apps to trust, Enter ticks or unticks the highlighted app, as space
  does, and a last row, Continue, confirms. In 0.3.0 Enter confirmed the list, so pressing it on an app closed the
  list with nothing picked.

Upgrading from 0.3.0: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`, then `blackice
start`, then restart the Mac. On macOS 27 an extension upgraded in place cannot be reached until the Mac restarts.

## 0.3.0 (3 November 2026)

An agent that answers, set up from the first start.

- `blackice agent connect fx` sets fx up to answer the connections that wait in ask mode: fx's installer if fx is
  missing (it asks first), a home of its own with the blackice skill (now inside Blackice.app), a sign-in, and rules
  that let it run only `blackice approve` and `blackice deny`; one test on a sample connection with a stand-in for
  `blackice`; then its rule and hook in `blackice.toml`, ask mode if you say so, one Touch ID and the daemon. Other
  agents are a profile each.
- The first `blackice start` asks from lists picked with the arrow keys: the mode, who answers in ask mode (fx or
  you), and the apps to trust, from the apps running now. Picking fx sets it up in the same command: accept-all
  until fx is installed, signed in and tested, then ask mode.
- `blackice agent connect` switches to accept-all while it sets an agent up if blackice is in ask or block-all, and
  reports a failed download by fx's installer.
- After saving the configuration, `start` waits for the network extension to answer before it goes on, so fx's
  sign-in is not cut when the filter comes up.
- fx's sign-in can read the terminal, so pressing Enter opens the page, and a failed sign-in is offered again. When
  AI Gateway refuses fx's test because the Vercel team has no card on file, `agent connect` says so.
- In ask and block-all, connections of Apple's developer tools (git over HTTPS, python3, notarytool and the rest of
  the Command Line Tools and Xcode) and of Mac App Store apps were dropped as `invalid_signature`, without asking,
  and no rule could name them. They are known now by their signing identifier and the Team ID `codesign -dv` shows:
  59GAB85EFG for Apple's tools, the developer's for Mac App Store apps.
- The install script takes `BLACKICE_ZIP`, the path of a `Blackice-<version>.zip` that is not published, to try a
  build with the same checks.

Upgrading from 0.2.1: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`, then `blackice
start`, then restart the Mac. On macOS 27 an extension upgraded in place cannot be reached until the Mac restarts.

## 0.2.1 (3 November 2026)

A first start that says what to do.

- The first `blackice start` is three numbered steps: pick a mode, confirm with Touch ID, allow the network
  extension. Each step has a title, and the lines fit an 80-column Terminal window.
- Allowing the extension is a numbered list of what to click, for the Mac's macOS version: on macOS 26 and later,
  General › Login Items, then ⓘ next to Blackice, then Network Extension. 0.2.0 named the macOS 15 place on every
  version, and on macOS 27 the list opens scrolled past Blackice.
- Before macOS asks whether Blackice may filter network content, `start` says to click Allow; if you click Don't
  Allow, it says how to try again.
- On a terminal, step titles and things to click are bold, checks green and commands cyan. `NO_COLOR` turns this off;
  pipes and logs get plain text.

Upgrading from 0.2.0: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`, then `blackice
start`, then restart the Mac. On macOS 27 an extension upgraded in place cannot be reached until the Mac restarts.

## 0.2.0 (3 November 2026)

Getting started, and what the command line says.

- `blackice start` with no `blackice.toml` asks a few questions and writes one: the mode, how long ask
  mode waits for an answer, and apps to allow, named by their path (`/Applications/Slack.app`,
  `/usr/bin/curl`) or their signing identifier. `blackice init` asks the same questions on its own.
- When macOS asks you to allow the network extension, `blackice start` opens System Settings at Login
  Items & Extensions and tells you what to turn on.
- `blackice status` says whether blackice is on, in which mode and what that mode does, whether the
  daemon is there to run your hooks, and how many connections are waiting.
- Plainer output everywhere. The Touch ID dialog reads "Blackice is trying to start filtering in
  block-all mode, 2 rules, no hooks", errors say what to do next, and nothing points at the
  repository's docs or shows internal numbers.
- `blackice version`.
- An install script: `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh`. It checks the
  checksum, the signature and the notarization before it copies the app.
- `blackice stop` succeeds when macOS finishes removing the extension at the next restart, instead of
  exiting with status 75.

Upgrading from 0.1.0: run the install script with `--force` (`curl -fsSL
https://blackice-macos.vercel.app/install.sh | sh -s -- --force`) or `brew upgrade --cask blackice`,
then `blackice start`, then restart the Mac. On macOS 27 an extension upgraded in place cannot be
reached until the Mac restarts.

## 0.1.0 (3 November 2026)

The first release.

- An application firewall for macOS with three modes: `accept-all` logs every new outbound
  connection, `block-all` lets through only what `blackice.toml` allows, and `ask` holds the rest
  until someone answers with `blackice approve` or `blackice deny`.
- Hooks: in ask mode a daemon runs a command for each held connection, so an agent such as fx can
  answer, with a one-time token per event.
- Touch ID for every change to filtering: start, stop, mode, and answers given by hand.
- Signed with a Developer ID and notarized; a zip on the GitHub release and a Homebrew cask
  (`valentintorassa/tap/blackice`).
