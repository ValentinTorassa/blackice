<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/public/brand/mark-dark.svg">
    <img src="site/public/brand/mark-light.svg" width="88" height="88" alt="blackice">
  </picture>
</p>

# blackice

blackice gives each app and each task on your machine its own network permissions, decided by a policy file.
It runs natively on macOS and Linux, with no prompts for anyone to answer.

Today it works for tasks: a command, such as one an AI agent runs, and everything that command starts. That is
tested on macOS and on Debian 13, and on macOS also inside fx's hook. For apps, the macOS app filter is built
and waits for Developer ID signing, and the Linux app filter is designed and being built.

## Status

blackice is at v0 and not production-ready. A cell is marked verified only when it has entries in
[`evidence/`](evidence/).

| | Apps | Tasks |
|---|---|---|
| macOS | Built, not signed yet: a Network Extension content filter ([#8](https://github.com/ValentinTorassa/blackice/pull/8)). It needs a Developer ID to run. | Verified: a Seatbelt sandbox profile plus a local proxy (experimental, because Apple has deprecated `sandbox-exec`). |
| Linux | Designed, being built. | Verified on Debian 13: cgroup v2 with eBPF socket programs plus a local proxy, and a small helper that a setup script installs with sudo. |
| Windows | Later | Later |

## Quick start

You need [Zig 0.17.0](https://ziglang.org/download/).

```console
$ git clone https://github.com/ValentinTorassa/blackice
$ cd blackice
$ zig build -Doptimize=ReleaseSafe
```

That builds `zig-out/bin/blackice`. On Linux, it also builds the helper. Read
[`scripts/linux-setup.sh`](scripts/linux-setup.sh), then install the helper once per boot:

```console
$ sha256sum zig-out/bin/blackice-linux-helper
$ sudo ./scripts/linux-setup.sh "$USER" <that sha256>
```

[`docs/linux.md`](docs/linux.md) covers the setup and teardown in detail. macOS needs no setup.

Write a policy that allows one name:

```json
{
  "version": "blackice.policy/v0",
  "network": { "mode": "allowlist", "allow": ["example.com"] }
}
```

Run a command under it. The allowed name works:

```console
$ ./zig-out/bin/blackice run --policy policy.json -- curl -sS -o /dev/null -w '%{http_code}\n' https://example.com
blackice: scope s-1b1f4870 (policy 353b7e8328f9, linux-cgroup-bpf); receipts: ~/.local/state/blackice/scopes/s-1b1f4870/receipts.jsonl
blackice: to allow one more host for a while: blackice grant s-1b1f4870 HOST --for 10m
200
blackice: scope s-1b1f4870 ended with status 0; 5 receipts
```

Any other name is refused:

```console
$ ./zig-out/bin/blackice run --policy policy.json -- curl -sS -o /dev/null -w '%{http_code}\n' https://github.com
blackice: scope s-f79c31a5 (policy 353b7e8328f9, linux-cgroup-bpf); receipts: ~/.local/state/blackice/scopes/s-f79c31a5/receipts.jsonl
blackice: to allow one more host for a while: blackice grant s-f79c31a5 HOST --for 10m
curl: (56) CONNECT tunnel failed, response 403
000
blackice: scope s-f79c31a5 ended with status 56; 5 receipts
```

Each decision is one JSON line in the scope's `receipts.jsonl`:

```json
{"ts":"2026-10-30T14:36:01.279Z","scope":"s-1b1f4870","policy":"353b7e8328f9","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"allowed_by_rule","rule":"example.com","host":"example.com","ip":"104.20.23.154","port":443,"detail":"sni_match"}
{"ts":"2026-10-30T14:36:01.427Z","scope":"s-f79c31a5","policy":"353b7e8328f9","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"github.com","port":443}
```

Receipts live under `$XDG_STATE_HOME/blackice/scopes/`, or `~/.local/state/blackice/scopes/` when that is not
set. `blackice policy check policy.json` validates a policy without running anything.

## How it works

- A **task scope** wraps a command and every process it starts: `blackice run --policy policy.json -- <command>`.
  The policy is in place before the command runs.
- An **app scope** applies a policy to an app that is already installed, however it was opened. See
  [Status](#status) for where each platform is.
- A planned **host ceiling** sits over every scope. Nested scopes can only narrow it.
- The policy is a strict JSON file (`blackice.policy/v0`): a mode (`deny-all`, `allow-all` or `allowlist`),
  allowed names, subnets and ports. Unknown fields are rejected. See [`docs/policy.md`](docs/policy.md).
- A command in a scope reaches the network only through a local proxy outside it. The proxy checks every name
  against the policy, and checks every address it resolves again.
- Only the owner can widen a scope, from outside it, for a limited time: `blackice grant SCOPE HOST --for 10m`.
- Each decision leaves a receipt: the scope, the policy hash and generation, where it was enforced, the verdict,
  a stable reason code and the destination.
- No model or remote service takes part in a decision. No account, no telemetry.

## Evidence

The runs were on macOS 27.0.1 on Apple silicon with SIP on, and on Debian 13 (kernel 6.12.113) on x86_64. Each
entry names the commit it was built from, the exact commands, the receipts and its own limits.

| Checkpoint | What it shows | macOS | Linux |
|---|---|---|---|
| P0-01 | A command whose policy does not load, or does not match its pinned hash, never starts. A valid policy is in place before the command does any work. | [entry](evidence/P0-01-policy-before-exec-macos.md) | [entry](evidence/P0-01-policy-before-exec-linux.md) |
| P0-02 | Direct TCP and UDP over IPv4 and IPv6 are refused. A receiver on another machine got nothing from inside the scope. | [entry](evidence/P0-02-real-deny-macos.md) | [entry](evidence/P0-02-real-deny-linux.md) |
| P0-03 | With an allowlist, the allowed names are reached through the proxy and other names are refused, with a receipt for each decision. | [entry](evidence/P0-03-explicit-allow-macos.md) | [entry](evidence/P0-03-explicit-allow-linux.md) |
| P0-04 | A command inside a scope cannot widen its own policy. The owner's `blackice grant`, from outside, lets one more name through until an end time. | [entry](evidence/P0-04-owner-grant-macos.md) | [entry](evidence/P0-04-owner-grant-linux.md) |
| P0-05 | When the grant ends, the proxy resets the connection opened under it, and a new connection to that name is refused. | [entry](evidence/P0-05-grant-expiry-macos.md) | [entry](evidence/P0-05-grant-expiry-linux.md) |
| P0-07 | With fx 0.0.16 and the blackice hook patch, every shell command fx runs gets its own scope and receipts. The run used a scripted test model. | [entry](evidence/P0-07-fx-hook-scripted-macos.md) | |

## Limits

- Network only. Files, processes and credentials need their own controls.
- The CLI and the policy format can still change.
- Only HTTP and TLS through the proxy can be allowed.
- Processes of the same user outside every scope count as the owner.
- Nothing inside a task scope can listen, not even on loopback, so dev servers and tests that open a port cannot
  run inside one.
- blackice does not detect prompt injection. It blocks connections the policy does not allow; what is sent to an
  allowed destination is up to that destination.
- Work handed to a daemon outside the task (docker, launchd, a tmux server) runs outside the task.
- With fx, only the shell commands fx runs are scoped. fx's own file tools and its model traffic run outside
  the scopes, and what those tools read goes to the model's provider.
- On macOS, a refusal leaves a receipt only when the refused program is signed by Apple. A program you built
  yourself is still refused, without a receipt. Programs signed with a Developer ID were not tested. A burst of
  refusals can lose receipts, and a process that outlives the command gets none.
- On Linux, ping, SCTP and raw sockets are refused when they are created, so they leave no receipt. Only x86_64
  was run. On Ubuntu 24.04 and later, where `kernel.apparmor_restrict_unprivileged_userns=1` is the default,
  scopes are expected to fail closed. Ubuntu was not tested.

## fx

Since 0.0.5, [fx](https://github.com/vercel-labs/fx) runs approved commands as ordinary host subprocesses
([changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md)). There are two ways to use blackice
with it:

- **A scope per command.** A small patch to fx's PreToolUse hook, in [`integrations/fx/`](integrations/fx/) and
  not part of fx upstream, runs every shell command fx launches as `blackice run`.
- **One scope around fx.** `blackice run --policy policy.json -- fx` puts fx and everything it starts in one
  task scope, with no changes to fx. This mode has no evidence entry yet.

## Site and docs

The project page and the documentation live in [`site/`](site/), a static Next.js export with its own pinned
dependencies. The native product does not import or build anything from it.

```console
$ cd site && npm ci && npm run dev
```

## Related projects

[sandbox-runtime](https://github.com/anthropics/sandbox-runtime) ·
[nono](https://github.com/nolabs-ai/nono) ·
[fence](https://github.com/fencesandbox/fence) ·
[OpenSnitch](https://github.com/evilsocket/opensnitch) ·
[LuLu](https://github.com/objective-see/LuLu) ·
[Vercel Sandbox firewall](https://vercel.com/docs/sandbox/concepts/firewall)

## Security

See [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE)
