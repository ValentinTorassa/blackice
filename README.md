# blackice

blackice is a network extension for macOS with a command-line interface and no other UI. It runs as a daemon
and sees every new outbound connection on the machine, from any app. It has three modes: accept all, block all and
ask. In ask mode a new connection waits while a hook asks an agent, such as [fx](https://github.com/vercel-labs/fx),
whether to allow it, and the agent answers with `blackice approve`.

**Status: early. The signed extension first ran on 3 November 2026, on one Mac:** the phase 0 check passed
([`docs/phase-0.md`](docs/phase-0.md)), and ask mode with fx deciding through a hook approved one connection,
denied another and dropped one nobody answered. Nothing is packaged or ready to use. The phases, the decisions
and the open problems are in [`docs/plan.md`](docs/plan.md).

## Who's building it and why

We're [Valen Torassa](https://valentorassa.com) and [Esteban Suárez](https://github.com/suarezesteban).

Agents run on developer machines all day, and we want them to decide about network access themselves, without
anyone clicking Allow in a dialog. The macOS firewalls we know are built around a person answering prompts.

The code that sees every connection on a machine is a sensitive place for a dependency. We'd rather own that code,
keep it small and readable, than install a third-party firewall with that access.

## How it will work

```toml
# blackice.toml (proposal)
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 10    # no answer in time means deny
apple_services = true   # macOS's own services reach Apple's hosts without a rule (the default)

# Permanent rules, checked before anything is asked.
[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]    # exact hosts or "*.domain"

[[hook]]
on = "connection"
run = 'fx ask "Use the blackice skill to decide whether to approve the pending connection"'
```

1. A new connection that no rule covers is paused by the network extension.
2. The blackice daemon receives the event and runs the hook, with the event as JSON on stdin and in a file named in
   `BLACKICE_EVENT_FILE`. The daemon runs as a LaunchAgent (`blackice agent install`) and takes its hooks from the
   configuration that `blackice start` saved with Touch ID, never from a file.
3. The agent answers, for example `blackice approve --app <signing id> --host example.com --for 1h`.
4. The extension lets the paused connection through, or drops it when the timeout passes.

Approvals cover one app and one host, expire, and live in memory only. Permanent rules go in `blackice.toml`.
An approval needs the one-time token that came with the event, or Touch ID from a person at the keyboard.

A rule names an app by its signing identifier and Team ID (none for Apple's own programs) and lists hosts. It
counts only when the address the app connects to is among the host's answers from the system resolver.

- `hosts = ["*"]`, alone in a rule, lets that app reach any destination, including connections made by address
  with no host name. VPN clients and DNS proxies need it: with Tailscale's DNS on, Tailscale's network extension
  forwards every lookup by address, and without such a rule names stop resolving in ask and block-all. The risk is
  that everything the app does is allowed, with no host or address check.

  ```toml
  [[allow]]
  app = "io.tailscale.ipn.macsys.network-extension"   # the standalone Tailscale build
  team = "W5364U7YZB"
  hosts = ["*"]
  ```

- macOS's own services (iCloud, push notifications, Software Update, Maps, certificate checks and a few more) are
  allowed by a built-in list, so ask mode doesn't ask about them. Each entry is one Apple program and the Apple
  hosts it uses. It matches only code Apple signed as part of macOS, and the address check applies as for a rule.
  Tools that fetch whatever they're given (curl, nscurl, python3, ssh, git, osascript, Safari, WebKit's
  networking process, nsurlsessiond) are not on it. `apple_services = false` turns the list off.

## Relation to the first proof of concept

The first blackice, now [blackice-poc](https://github.com/ValentinTorassa/blackice-poc) and archived, confines one
command and everything it starts, with a fixed policy file, and never asks. This blackice covers the whole machine and
asks an agent about each new connection. The architecture was worked out in blackice-poc, and this code starts from
its macOS app filter: the Network Extension, app identity from code signatures, and the TLS server name reader. Until
2 November 2026 this project was called netshield.

## Code so far

[`macos/`](macos/) is a Swift package that builds with the Command Line Tools alone:

- the `blackice.toml` reader, strict: an unknown key, a duplicate key or anything outside the
  small TOML subset the file uses is an error with its line number;
- the event a hook receives and its one-time token;
- the `blackice` command. `blackice validate PATH` checks a configuration file. `blackice agent
  install` loads the daemon's LaunchAgent and must run from inside Blackice.app; `agent uninstall`
  removes it. Every other command (`start`, `stop`, `status`, `mode`, `pending`, `approve`, `deny`
  and `daemon`) needs Blackice.app signed with the Developer ID; any other build says so and exits
  with status 69;
- the network extension, a content filter: accept-all allows every connection, block-all allows only
  what an `[[allow]]` rule or the built-in list of macOS services names, and ask also allows what a
  current approval names and pauses the rest until a hook or a person answers. A rule, list entry or
  approval counts only when the address the app connects to is among the host's answers from the
  system resolver; a `hosts = ["*"]` rule skips that check. A connection made to an address, with no
  host name (`curl` and most command-line tools), is named from the system resolver's DNS answers,
  which the extension reads in ask and block-all and passes on unchanged, or else from its TLS server
  name. Ad hoc signed code is approved by its cdhash;
- ask mode's state (approvals, paused connections, one-time tokens, deadlines) and the XPC messages
  between the extension, the daemon and the CLI. These and the extension's decision are plain code
  with unit tests; the NetworkExtension and XPC code around them has run on one Mac, with no automated tests;
- scripts in `macos/scripts/` that build Blackice.app without Xcode, sign it, and run the phase 0
  check;
- from blackice-poc's macOS app filter: app identity from code signatures, host name rules, the TLS
  server name reader, and the filter provider and activation code the extension and CLI adapt.

```console
$ macos/test.sh     # swift test
$ macos/smoke.sh    # builds and runs the binary
$ cd macos && swift run blackice validate Examples/blackice.toml
$ DRY=1 macos/scripts/sign.sh ABCDE12345 - -   # assembles Blackice.app, signed ad hoc
```

[`integrations/fx/`](integrations/fx/) holds a draft skill for fx to decide connections.

## Site

The project page lives in [`site/`](site/), a Next.js app with Cache Components. The docs are MDX, and every
page has a markdown twin listed in `/llms.txt`.

```console
$ cd site && npm ci && npm run dev
```

## License

[Apache-2.0](LICENSE)
