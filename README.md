# blackice

An application firewall for macOS that you run from the command line. It sees every new outbound connection, from
any app, and has three modes:

- `accept-all` lets everything through and logs it.
- `block-all` lets through only what your rules allow.
- `ask` pauses any connection no rule covers until someone answers. A hook can pass the question to an agent such as
  [fx](https://github.com/vercel-labs/fx), which answers with `blackice approve` or `blackice deny`.

There is no window or menu bar icon. Starting, stopping and changing the mode take Touch ID.

Docs: [blackice-macos.vercel.app](https://blackice-macos.vercel.app)

## Status

Early. 0.3.0 is the current release ([changelog](CHANGELOG.md)), and blackice has run on one Mac, a MacBook Air with
macOS 27.0.1. Each run is recorded in
[`evidence/`](evidence/):

- block-all refused a binary that no rule named, and let `curl` through with a rule (P0-01).
- In ask mode, fx approved and denied connections through the hook (P2-01, P2-02), and decided ten in a row with
  nobody at the keyboard, nine as expected (P4-01). `curl` and other tools that connect to an address fail on the
  first try and get through on the retry after the approval.
- The fault tests passed for a stopped daemon, a hung hook, a burst of 120 connections and a daemon restart. A
  configuration change while connections wait failed with build 4 (P5-01) and passed with 0.2.1 (P5-04).
- After an upgrade in place, the Mac needed a restart (P5-02).
- From the published 0.2.1: uninstalling by following the install guide, the curl install script into `/Applications`
  (checksum, signature and notarization checked), the first `start`, and the fault tests with all 28 checks passing
  (P5-04).
- `blackice agent connect fx` set fx up to answer ask mode in one command on a trial build (P5-05).
- With 0.3.0 candidates and no blackice or fx on the Mac: the first `start` asked with lists, then installed fx and
  signed it in. fx's test failed with HTTP 403 for a Vercel team with no card on file. With an earlier sign-in,
  `agent connect fx` loaded ask mode, and fx approved two `nscurl` requests in about 5 s (P5-06).
- In ask mode, candidate build 11 dropped git over HTTPS, `notarytool` and Apple's other developer tools without
  asking. Build 13, the 0.3.0 release, asks about them, and fx approved git and `notarytool` in about 5 s (P5-07).

Open problems are in [`docs/plan.md`](docs/plan.md).

## Install

Apple silicon and macOS 14 or later.

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
```

The script ([`site/lib/install.sh`](site/lib/install.sh)) checks the release zip's checksum, signature and
notarization, copies Blackice.app to /Applications and adds a `blackice` command to `~/.local/bin`. Or with Homebrew:

```console
$ brew trust --cask valentintorassa/tap/blackice
$ brew install --cask valentintorassa/tap/blackice
```

Or download the zip from the [release](https://github.com/ValentinTorassa/blackice/releases/tag/v0.3.0). The first
`blackice start` asks a few questions to write your configuration, then opens System Settings so you can allow the
extension. `blackice agent install` starts the daemon
that runs hooks. Run `blackice stop` before you uninstall. [`docs/install.md`](docs/install.md) has the rest.

## Configuration

```toml
# ~/.config/blackice/blackice.toml (the format can still change)
mode = "ask"
timeout_seconds = 10    # no answer in time means deny

[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]

[[hook]]
on = "connection"
run = 'fx ask "Use the blackice skill to decide whether to approve the pending connection"'
```

An approval covers one app and one host, expires, and needs the event's one-time token or Touch ID. Rules you want
to keep go in the file. The [configuration docs](https://blackice-macos.vercel.app/docs/configuration) cover every
key.

## Development

```console
$ macos/test.sh      # swift test
$ macos/smoke.sh     # builds and runs the CLI
$ cd site && npm ci && npm run dev
```

[`macos/`](macos/) is the Swift package: the CLI, the network extension and the daemon. [`integrations/fx/`](integrations/fx/)
has a draft fx skill, [`packaging/npm/`](packaging/npm/) an npm installer that isn't published yet, and
[`site/`](site/) the project page.

## Who

[Valen Torassa](https://valentorassa.com) and [Esteban Suárez](https://github.com/suarezesteban). Agents run on our
machines all day, and we want them to decide network access without anyone clicking Allow. blackice grew out of
[blackice-poc](https://github.com/ValentinTorassa/blackice-poc), now archived.

## License

[Apache-2.0](LICENSE)
