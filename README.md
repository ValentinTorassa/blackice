# blackice

An application firewall for macOS that you run from the command line. It sees every new outbound connection, from
any app, and has three modes:

- `accept-all` lets everything through and logs it.
- `block-all` lets through only what your rules allow.
- `ask` holds any connection no rule covers until you, or an agent such as Claude Code or
  [fx](https://github.com/vercel-labs/fx), approve or deny it.

A menu bar icon shows the mode and what waits. Starting, stopping, switching modes and answering take Touch ID.

Docs: [blackice-macos.vercel.app](https://blackice-macos.vercel.app)

1.0.1 has run on one Mac, a MacBook Air with macOS 27.0.1; macOS 14 and 15 are not tested yet. A `blackice.toml`
that works in 1.0 keeps working in every 1.x. Each run is recorded in [`evidence/`](evidence/),
each release in [CHANGELOG.md](CHANGELOG.md), and the open problems in [`docs/plan.md`](docs/plan.md).

## Install

Apple silicon and macOS 14 or later.

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
$ blackice start
```

Or with Homebrew:

```console
$ brew trust --cask valentintorassa/tap/blackice
$ brew install --cask valentintorassa/tap/blackice
```

The first `start` asks a few questions, writes `~/.config/blackice/blackice.toml` and opens System Settings so you
can allow the extension. [`docs/install.md`](docs/install.md) has the rest, uninstalling included, and the
[configuration docs](https://blackice-macos.vercel.app/docs/configuration) cover every key.

## Agents

`blackice agent connect NAME` sets an agent up to answer in ask mode: a home and sign-in of its own, one test on a
sample connection, a rule that lets it reach its model, and its hook. Its tools can only read.

- `fx`: [fx](https://github.com/vercel-labs/fx) ([`integrations/fx/`](integrations/fx/))
- `claude-code`: [Claude Code](https://code.claude.com) ([`integrations/claude-code/`](integrations/claude-code/))
- `codex`: [Codex](https://developers.openai.com/codex/cli), with a ChatGPT plan ([`integrations/codex/`](integrations/codex/))
- `opencode`: [opencode](https://opencode.ai/docs), with a provider you pick ([`integrations/opencode/`](integrations/opencode/))

[`integrations/eval/run.sh`](integrations/eval/run.sh) runs any of them over the same 33 cases.

## Development

```console
$ macos/test.sh      # swift test
$ macos/smoke.sh     # builds and runs the CLI
$ cd site && npm ci && npm run dev
```

[`macos/`](macos/) is the Swift package: the CLI, the network extension and the daemon. [`integrations/`](integrations/)
has each agent's instructions and the eval, [`packaging/npm/`](packaging/npm/) an npm installer that isn't published
yet, and [`site/`](site/) the project page.

## Who

[Valen Torassa](https://valentorassa.com) and [Esteban Suárez](https://github.com/suarezesteban). Agents run on our
machines all day, and we want them to decide network access without anyone clicking Allow. blackice grew out of
[blackice-poc](https://github.com/ValentinTorassa/blackice-poc), now archived.

## License

[Apache-2.0](LICENSE)
