# Changelog

## Unreleased

- The agents' instructions ship inside blackice. A `program` hook names them with `instructions = "fx"` or
  `"claude-code"`, and the daemon writes them into the event's private directory before the agent starts: fx's
  skill as `skills/blackice/SKILL.md`, Claude Code's system prompt as `instructions.md`. Up to 0.4.0 they were
  files in the agent's home, `~/.config/blackice/agent`, that any program running as you could rewrite to approve
  everything. `agent connect` writes the new key and removes those copies once the new hook is loaded.

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
