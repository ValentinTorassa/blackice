# blackice

An application firewall for macOS that you run from the command line. It sees every new outbound connection, from
any app, and has three modes:

- `accept-all` lets everything through and logs it, with what ask mode would have done (`blackice report` sums it
  up).
- `block-all` lets through only what your rules allow.
- `ask` pauses any connection no rule covers until someone answers. A hook can pass the question to an agent such as
  [fx](https://github.com/vercel-labs/fx), which answers with `blackice approve` or `blackice deny`.

There is no window. A menu bar icon shows the mode and what waits, and answers by hand. Starting, stopping and
changing the mode take Touch ID.

Docs: [blackice-macos.vercel.app](https://blackice-macos.vercel.app)

## Status

Early. 0.4.5 is the current release ([changelog](CHANGELOG.md)), and blackice has run on one Mac, a MacBook Air with
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
- From the published 0.3.0, recorded: the one-liner, then one `blackice start` to ask mode with fx answering in
  1 min 16 s. In the next ten minutes, bursts of connections from a VPN client outran fx, and 31 connections were
  dropped at the deadline (P5-08; see "Hooks in a burst" in the plan).

Open problems are in [`docs/plan.md`](docs/plan.md).

## Install

Apple silicon and macOS 14 or later.

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
```

The script ([`site/lib/install.sh`](site/lib/install.sh)) checks the release zip's checksum, signature, notarization
and version, copies Blackice.app to /Applications and adds a `blackice` command to `~/.local/bin`. Or with Homebrew:

```console
$ brew trust --cask valentintorassa/tap/blackice
$ brew install --cask valentintorassa/tap/blackice
```

Or download the zip from the [release](https://github.com/ValentinTorassa/blackice/releases/tag/v0.4.5). The first
`blackice start` asks a few questions to write your configuration, then opens System Settings so you can allow the
extension, and at the end offers the menu bar icon (`blackice menu --login on` adds it later). `blackice agent install`
starts the daemon that runs hooks. Run `blackice stop` before you uninstall. [`docs/install.md`](docs/install.md) has the
rest.

## Configuration

```toml
# ~/.config/blackice/blackice.toml (the format can still change)
mode = "ask"
timeout_seconds = 10    # no answer in time means deny

[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]    # host names, *.domain, IP addresses and CIDR ranges, or ["*"] alone

[[hook]]
on = "connection"
program = "/Users/me/.local/bin/fx"   # started only when its signature names app and team
app = "com.vercel.fx"
team = "JW6Y669B67"
args = ["ask", "--no-save", "--no-color", "Use the blackice skill to decide whether to approve the pending connection"]
env = ["HOME=/Users/me/.config/blackice/agent", "FX_DISABLE_KEYCHAIN=1"]
instructions = "fx"                   # written from blackice into the event's directory
```

A hook answers with the last line it prints, `deny` or `approve 10m`, and the daemon passes that on for the event's
app and host. A hook never sees the event's one-time token. An approval covers one app and one host, or one address for a
connection with no name, and expires; by hand, `blackice approve` needs Touch ID. Connections to 127.0.0.1 and ::1
pass unless `loopback = false`. Rules you want to keep go in the file. The [configuration docs](https://blackice-macos.vercel.app/docs/configuration) cover every
key.

## Agents

`blackice agent connect NAME` sets an agent up to answer what waits in ask mode, in one command: a home of its own
under `~/.config/blackice/agent`, one test on a sample connection, a rule that lets it reach its model, and the hook.

- `fx`: [fx](https://github.com/vercel-labs/fx) with the blackice skill ([`integrations/fx/`](integrations/fx/)).
- `claude-code`: [Claude Code](https://code.claude.com) in print mode, with reading the event as its only tool and a
  sign-in of its own ([`integrations/claude-code/`](integrations/claude-code/)). It ends its reply with a verdict
  line, such as `approve 12h` or `deny`. On 5 November 2026, with `haiku`, it decided the 23 eval cases as
  expected, in 4.2 s at the median.
- `codex`: [Codex](https://developers.openai.com/codex/cli) with `codex exec`, signed in with a ChatGPT plan, its
  commands able to read only the event's directory ([`integrations/codex/`](integrations/codex/)). On 5 November
  2026, with `gpt-6-luna`, it decided the 23 eval cases as expected, in 4.6 s at the median.
- `opencode`: [opencode](https://opencode.ai/docs) with `opencode run`, signed in to a provider you pick when you
  connect it (OpenAI, Z.AI Coding Plan, OpenCode Go, MiniMax Token Plan, OpenRouter or Anthropic), with reading the
  event's directory as its only tool and a rule for that provider's hosts ([`integrations/opencode/`](integrations/opencode/)).
  On 5 November 2026, with `openai/gpt-6-luna` on a ChatGPT plan, it decided the 23 eval cases as expected, in
  3.9 s at the median; with Z.AI's `glm-5.3-flash`, 22, in 12.8 s (it approved Slack on port 6667).

Each agent decides with a small model unless `--model NAME` names another: a decision is a short read and a
two-line answer. The instructions approve clearly ordinary developer and vendor traffic for 8 to 24 hours and
anything less plain for 10 minutes to an hour, so ordinary traffic is asked about once a day at most. One agent
answers at a time: each one you connect keeps its hook, `answers` in `[agent]` names the one that runs, and
`blackice mode ask --agent NAME` or the menu's Mode switches.
[`integrations/eval/run.sh`](integrations/eval/run.sh) runs any of them over the same 23 cases.

## Development

```console
$ macos/test.sh      # swift test
$ macos/smoke.sh     # builds and runs the CLI
$ cd site && npm ci && npm run dev
```

[`macos/`](macos/) is the Swift package: the CLI, the network extension and the daemon. [`integrations/fx/`](integrations/fx/)
has a draft fx skill, [`integrations/claude-code/`](integrations/claude-code/) Claude Code's instructions,
[`integrations/eval/`](integrations/eval/) the eval for every agent, [`packaging/npm/`](packaging/npm/) an npm installer that isn't published yet, and
[`site/`](site/) the project page.

## Who

[Valen Torassa](https://valentorassa.com) and [Esteban Suárez](https://github.com/suarezesteban). Agents run on our
machines all day, and we want them to decide network access without anyone clicking Allow. blackice grew out of
[blackice-poc](https://github.com/ValentinTorassa/blackice-poc), now archived.

## License

[Apache-2.0](LICENSE)
