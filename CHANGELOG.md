# Changelog

## Unreleased

Changed:
- For now the menu's Mode and the first `start`'s list leave Codex and opencode out: Mode lists Accept All, Ask
  with fx, Claude Code and you, and Block All, and shows Codex or opencode once it is connected. Nothing else
  changes: `blackice agent connect codex|opencode` sets them up and `blackice mode ask --agent` switches to them.

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
