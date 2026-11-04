# Changelog

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
