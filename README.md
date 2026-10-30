<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/public/brand/mark-dark.svg">
    <img src="site/public/brand/mark-light.svg" width="88" height="88" alt="blackice">
  </picture>
</p>

# blackice

blackice decides which hosts a command can reach, along with every process that command starts. The rules are in
place before the command runs, and nothing inside can loosen them. For macOS and Linux, native and headless.

**v0, not ready for production.** What has been tested is listed under [Evidence](#evidence). Everything else is
untested.

## How it works

```console
$ blackice run --policy policy.json -- <command>
```

```json
{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["example.com", "registry.npmjs.org", "ai-gateway.vercel.sh"]
  }
}
```

- The policy is in place before `<command>` starts, and every process it starts inherits it.
- The command reaches the network only through a local proxy that runs outside the scope. The proxy checks each
  name against the policy, then checks every address that name resolves to.
- Nothing inside a scope can widen its own policy. The owner can, from outside, for a limited time
  (`blackice grant`).
- The policy is a strict JSON file: a mode (`deny-all`, `allow-all` or `allowlist`) plus allowed names, subnets and
  ports. Unknown fields are an error.
- Every decision is written as one JSON line with the scope, the policy hash and generation, where it was enforced,
  the verdict, a reason code and the destination.
- Planned: app scopes for apps already on the machine, and a host-wide ceiling above every scope. Nested scopes
  can only narrow.

The CLI may still change.

## Platforms

| | Apps | Agent tasks |
|---|---|---|
| macOS | Network Extension filter, built but unsigned ([#8](https://github.com/ValentinTorassa/blackice/pull/8), not merged). It needs an Apple Developer ID to run. | macOS sandbox (Seatbelt) plus the local proxy ([#7](https://github.com/ValentinTorassa/blackice/pull/7)). Experimental, with recorded runs below. |
| Linux | Not built. Grouping apps by the desktop's systemd scopes still has to be proven. | cgroup v2 with eBPF socket programs, a small helper installed once with `sudo`, and the local proxy. Built in [#6](https://github.com/ValentinTorassa/blackice/pull/6), not merged; on main, `blackice run` refuses to start on Linux. |
| Windows | Later | Later |

## Evidence

macOS agent tasks, on macOS 27.0.1, Apple silicon, SIP on, with release builds of 58e73cc (P0-05: 58b9491). We
ran these ourselves before the code was merged; nobody else has reproduced them yet, and there is no video. Each
entry lists its own limits.

| Checkpoint | What it shows |
|---|---|
| [P0-01](evidence/P0-01-policy-before-exec-macos.md) | The policy is in place before the command's first instruction: its first connection is refused, and so are a grandchild started later and one that outlives the command. If the policy doesn't load, or doesn't match its pinned hash, the command never starts. |
| [P0-02](evidence/P0-02-real-deny-macos.md) | Inside a scope, a command can't open a TCP connection, send UDP over IPv4 or IPv6, look up a name, listen, or get launchd to start a job for it. A receiver on another machine got nothing from inside the scope, and did get the same sender from outside it. |
| [P0-03](evidence/P0-03-explicit-allow-macos.md) | With a policy that allows only `example.com`, the command reaches example.com over HTTPS and plain HTTP. github.com is refused on both, and every connection leaves a receipt. |
| [P0-04](evidence/P0-04-owner-grant-macos.md) | A command inside a scope can't widen its own policy. The owner's `blackice grant`, run from outside, lets exactly one more name through until a set time. |
| [P0-05](evidence/P0-05-grant-expiry-macos.md) | When the grant ends, the proxy resets the connection opened under it within milliseconds, and new connections to that name are refused again. |
| [P0-07](evidence/P0-07-fx-hook-scripted-macos.md) | fx 0.0.16 with the blackice hook patch, in full-access mode, driven by a scripted test model (a run with a real model is pending). Every shell command fx runs gets its own scope and receipts, and no command can change blackice, fx, the policy or fx's settings. fx's `write_file` outside the workspace and its `web_fetch` are blocked. Not covered: fx's own file reads, its writes inside the workspace and its model traffic run outside the scopes, and what fx reads goes to the model provider. |

## Limits

- Network only. Files, processes and credentials need other tools.
- On macOS, a refused connection leaves a receipt only when the program is signed by Apple. Ad-hoc-signed
  programs, like one you built yourself, are still refused but leave no receipt. Programs signed with a Developer
  ID weren't tested. A burst of refusals can drop receipts, and a process that outlives the command gets none.
- In v0, only HTTP and TLS through the proxy can be allowed.
- In v0, any process of the same user outside every scope counts as the owner.
- In v0, nothing inside a task scope can listen, not even on loopback, so dev servers and tests that open a port
  can't run inside one.
- It doesn't detect prompt injection. It blocks connections the policy doesn't allow; what gets sent to an allowed
  destination is out of scope.
- Work handed to a daemon outside the task (docker, launchd, a tmux server) runs outside the scope.
- No model or remote service takes part in a decision. No account, no telemetry.

## fx

Since 0.0.5, [fx](https://github.com/vercel-labs/fx) runs approved commands as ordinary host subprocesses
([changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md)). There are two ways to put blackice in
front of it:

- **One scope per command.** A small patch to fx's PreToolUse hook, kept in `integrations/fx/` and not part of fx
  upstream, runs every shell command fx launches through `blackice run`, each with its own scope and receipts.
  This is what P0-07 tested.
- **One scope around fx.** `blackice run --policy policy.json -- fx` will run fx and everything it starts in a
  single scope, with no changes to fx.

## Site and docs

The project page and the docs live in [`site/`](site/), a static Next.js export with its own pinned dependencies.
The native product doesn't import or build anything from `site/`.

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
