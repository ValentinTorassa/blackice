# blackice

An application firewall for macOS that you run from the command line. It sees every new outbound connection, from
any app, and has three modes:

- `accept-all` lets everything through and logs it.
- `block-all` lets through only what your rules allow.
- `ask` holds any connection no rule covers until you, or an agent such as Claude Code or
  [fx](https://github.com/vercel-labs/fx), approve or deny it.

A menu bar icon shows the mode and what waits. Starting, stopping, switching modes and answering take Touch ID.

Docs: [blackice-macos.vercel.app](https://blackice-macos.vercel.app)

1.1.0 has run on one Mac, a MacBook Air with macOS 27.0.1; macOS 14 and 15 are not tested yet. A `blackice.toml`
that works in 1.0 keeps working in every 1.x. Each run is recorded in [`evidence/`](evidence/),
each release in [CHANGELOG.md](CHANGELOG.md), and the open problems in [`docs/plan.md`](docs/plan.md).

## Install

Apple silicon and macOS 14.4 or later.

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

[`integrations/eval/run.sh`](integrations/eval/run.sh) runs any of them over the same 44 cases, and 12 more with an owner's notes (`CASES=cases-notes.json`).

## Safety approach

An agent running on your Mac can send data to a new destination before you see what it is doing. In ask mode,
blackice holds that outbound connection outside the agent, in a macOS network extension. The deciding hook can
approve or deny only the app and destination of the event it received, for at most 24 hours. Changing the saved
rules or answering by hand takes Touch ID; the hook does not receive the event's authorization token.

App names and host names are untrusted input to the deciding agent. Its instructions say to treat them as data,
and the daemon accepts only a verdict with a bounded duration. That limits what a bad answer can authorize; it
does not make the agent's judgment reliable. If nobody answers, the connection is dropped at its deadline.

## Evidence and limitations

[`evidence/`](evidence/) records live runs, their configuration and failures, made by the people building
blackice. These are not independent tests. For the 1.0.8 candidate,
[P5-23](evidence/P5-23-upgrades-interrupts-faults-evals-1.0.8-candidate-macos.md) records 29 of 29 fault checks,
44 of 44 base cases and 12 of 12 cases with notes for fx and Claude Code, and 43 of 44 and 11 of 12 for Codex.
The cases are a small evaluation set, not a measure of safety against arbitrary attacks.

blackice controls new outbound connections, not file writes, local commands or the contents of a request to an
allowed service. It cannot undo an action. A harmful request to an already allowed destination can still pass.
It is not a sandbox against another program running as the same user: agent homes and prompt injection remain
attack surfaces. Decisions can be wrong, and bursts or a slow model can drop legitimate connections.
[Open problems](docs/plan.md#open-problems) describes these limits and the remaining work. Live evidence so far
comes from one Mac; the supported older macOS versions still need testing.

## When nobody answers

In ask mode a connection waits until `timeout_seconds` in `blackice.toml` (10 s by default, at most 120). If no one
answers by then, it is dropped: nothing piles up for later. While it waits, `blackice pending` lists it with the
`blackice approve` line that lets it through, so you can still answer it yourself. A denial is remembered for 10
minutes, and the app's new connections to that host are dropped without asking. At most 4 hooks run at once and up
to 256 wait their turn; a waiting hook is skipped when its connection has ended or its deadline is too close.

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
