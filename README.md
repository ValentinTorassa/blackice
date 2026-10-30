<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/public/brand/mark-dark.svg">
    <img src="site/public/brand/mark-light.svg" width="88" height="88" alt="blackice">
  </picture>
</p>

# blackice

Network permissions for apps and agent tasks on macOS and Linux. Native and headless.

> **Status: proof of concept, not production.** Only macOS agent tasks have evidence entries so far (see
> [Evidence](#evidence)); everything else is not verified yet. A capability is listed as working only when a
> recorded test backs it; see [`evidence/`](evidence/). Parts that are not built yet are written in the future tense.

## Design

- A **task scope** wraps a command and every process it starts:
  `blackice run --policy policy.json -- <command>`. The policy is armed before the command runs.
- An **app scope** will apply a policy to an app already on the machine.
- A **host ceiling** will sit over every scope. Nested scopes can only narrow.
- The policy is a strict JSON file (`blackice.policy/v0`): a mode (`deny-all`, `allow-all` or `allowlist`),
  allowed names, subnets and ports. Unknown fields are rejected.
- A command inside a scope reaches the network only through a local proxy outside it, which checks every name
  against the policy and every resolved address again.
- Only the owner can widen a scope, from outside it, for a limited time.
- Each decision is one flat JSON line: the scope, the policy hash and generation, where it was enforced, the
  verdict, a stable reason code and the destination.

The CLI is not frozen yet.

## Platforms

Only the macOS agent-task cell has evidence entries ([Evidence](#evidence)). Every other cell is not verified.

| | Apps | Agent tasks |
|---|---|---|
| macOS | Network Extension content filter: built, unsigned ([#8](https://github.com/ValentinTorassa/blackice/pull/8)). It cannot run until it is signed with a Developer ID. | Seatbelt task scope with a local proxy, experimental ([#7](https://github.com/ValentinTorassa/blackice/pull/7)). Evidence entries P0-01 to P0-05 and P0-07 |
| Linux | Not built. Grouping apps by the desktop's systemd scopes still has to be proven. | cgroup v2 with eBPF socket programs and a small privileged helper, installed once with a setup script run with sudo, plus a local proxy ([#6](https://github.com/ValentinTorassa/blackice/pull/6)) |
| Windows | Later, not part of the first release | Later, not part of the first release |

## Evidence

macOS agent tasks only: macOS 27.0.1 on Apple silicon with SIP on, release builds of `claude/run` at 58e73cc
(P0-05 at 58b9491), run by the people who built it, with no video of the runs yet. Each entry states its own limits.

| Checkpoint | What the entry shows |
|---|---|
| [P0-01](evidence/P0-01-policy-before-exec-macos.md) | The policy is in place before the command's first instruction: its first network call is refused, and so are a grandchild started later and one that outlives the command. A command whose policy does not load, or does not match its pinned hash, never starts. |
| [P0-02](evidence/P0-02-real-deny-macos.md) | A command in a scope cannot open a TCP connection or send a UDP datagram over IPv4 or IPv6, look up a name, listen, or have launchd start a job for it. A receiver on another machine got nothing from inside the scope, while the same sender reached it from outside. |
| [P0-03](evidence/P0-03-explicit-allow-macos.md) | With a policy that allows only `example.com`, the command reaches example.com over HTTPS and plain HTTP; github.com is refused on both, with a receipt for each connection. |
| [P0-04](evidence/P0-04-owner-grant-macos.md) | A command inside a scope cannot widen its own policy. The owner's `blackice grant` from outside lets exactly one more name through, with an end time. |
| [P0-05](evidence/P0-05-grant-expiry-macos.md) | When the owner's grant ends, the proxy resets the connection opened under it within milliseconds, and a new connection to that name is refused again. |
| [P0-07](evidence/P0-07-fx-hook-scripted-macos.md) | With fx 0.0.16 and the blackice hook patch, in full-access mode and with a **scripted test model, not a real model**, every shell command fx runs gets its own scope and receipts, and a command cannot change blackice, fx, the policy or fx's settings. fx's `write_file` outside the workspace and its `web_fetch` are blocked; fx's own reads (`read_file`, `glob_files`, `grep_files`), its writes inside the workspace and its model traffic still run outside the scopes, and what they read goes to the model's provider. A run with a real model is pending. |

Linux task scopes, the app filter and Windows are not verified.

## Limits

- Network only. Files, processes and credentials need their own controls.
- On macOS, a refusal is logged, and so gets a receipt, only when the refused program is signed by Apple. An
  ad-hoc-signed program, such as one you built yourself, is still refused, but leaves no receipt. Programs signed
  with a Developer ID were not tested. Even then, a burst of refusals can lose some receipts, and a process that
  outlives the command gets none.
- In v0, only HTTP and TLS through the proxy can be allowed.
- In v0, processes of the same user outside every scope count as the owner.
- In v0, nothing inside a task scope can listen, not even on loopback. Dev servers and tests that open a port
  cannot run inside a scope.
- It does not detect prompt injection. It blocks connections the policy does not allow. Data sent to an allowed
  destination is out of scope.
- Work handed to a daemon outside the task (docker, launchd, a tmux server) runs outside the task.
- No model or remote service takes part in a verdict. No account, no telemetry.

## fx

Since 0.0.5, [fx](https://github.com/vercel-labs/fx) runs approved commands as ordinary host subprocesses
([changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md)). Two ways to use blackice with it:

- **A scope per command.** A small patch to fx's PreToolUse hook, kept in `integrations/fx/` and not part of fx
  upstream, runs every shell command fx launches as `blackice run`, each with its own scope and receipts.
- **One scope around fx.** `blackice run --policy policy.json -- fx` will put fx and everything it starts in one
  task scope, with no changes to fx.

## Site and docs

The project page and the documentation live in [`site/`](site/): a static Next.js export with its own pinned
dependencies. Nothing in the native product imports or builds anything from `site/`.

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
