# netshield

netshield is a network extension for macOS with a command-line interface and no other UI. It runs as a daemon
and sees every new outbound connection on the machine, from any app. It has three modes: accept all, block all and
ask. In ask mode a new connection waits while a hook asks an agent, such as [fx](https://github.com/vercel-labs/fx),
whether to allow it, and the agent answers with `netshield approve`.

**Status: planning. Nothing here runs yet.** Phase 0, signing with an Apple Developer ID, is in progress. The
phases and the decisions behind them are in [`docs/plan.md`](docs/plan.md).

## Why I'm building it

I'm [Valen Torassa](https://valentorassa.com), a security and backend engineer in Rosario, Argentina. Agents run on
my machines all day, and I want them to decide about network access themselves, without anyone clicking Allow in a
dialog. The macOS firewalls I know are built around a person answering prompts.

The code that sees every connection on a machine is a sensitive place for a dependency. I'd rather own that code,
keep it small and readable, than install a third-party firewall with that access.

## How it will work

```toml
# netshield.toml (proposal)
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 10    # no answer in time means deny

[[hook]]
on = "connection"
run = 'fx -p "Use the netshield skill to decide if this connection should be approved"'
```

1. A new connection that no rule covers is paused by the network extension.
2. The netshield daemon receives the event and runs the hook, with the event as JSON on stdin.
3. The agent answers, for example `netshield approve --app <signing id> --host example.com --for 1h`.
4. The extension lets the paused connection through, or drops it when the timeout passes.

Approvals cover one app and one host, expire, and live in memory only. Permanent rules go in `netshield.toml`.
An approval needs the one-time token that came with the event, or Touch ID from a person at the keyboard.

## Relation to blackice

[blackice](https://github.com/ValentinTorassa/blackice) confines one command and everything it starts, with a fixed
policy file, and never asks. netshield covers the whole machine and asks an agent about each new connection.
blackice was where I worked out the architecture. netshield starts from its macOS app filter: the Network Extension,
app identity from code signatures, and the TLS server name reader.

## Site

The project page lives in [`site/`](site/), a static Next.js export.

```console
$ cd site && npm ci && npm run dev
```

## License

[Apache-2.0](LICENSE)
