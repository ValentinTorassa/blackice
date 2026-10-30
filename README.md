<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/public/brand/mark-dark.svg">
    <img src="site/public/brand/mark-light.svg" width="88" height="88" alt="blackice">
  </picture>
</p>

# blackice

Network permissions for apps and agent tasks on macOS and Linux. Native and headless.

> **Status: proof of concept, not production.** Nothing here is verified yet. A capability is listed as working
> only when a recorded test backs it; see [`evidence/`](evidence/). Parts that are not built yet are written in
> the future tense.

## Design

- A **task scope** will wrap a command and every process it starts:
  `blackice run --policy policy.json -- <command>`. The policy will be armed before the command runs.
- An **app scope** will apply a policy to an app already on the machine.
- A **host ceiling** will sit over every scope. Nested scopes can only narrow.
- The policy is a strict JSON file (`blackice.policy/v0`): a mode (`deny-all`, `allow-all` or `allowlist`),
  allowed names, subnets and ports. Unknown fields are rejected.
- A command inside a scope will reach the network only through a local proxy outside it, which checks every name
  against the policy and every resolved address again.
- Only the owner will be able to widen a scope, from outside it, for a limited time.
- Each decision is one flat JSON line: the scope, the policy hash and generation, where it was enforced, the
  verdict, a stable reason code and the destination.

The CLI is not frozen yet.

## Platforms (planned)

| | Apps | Agent tasks |
|---|---|---|
| macOS | Network Extension filter (needs Developer ID signing) | Seatbelt session with a local proxy (experimental) |
| Linux | Chosen after a spike | cgroup v2 with eBPF, plus a local proxy |

## Limits

- Network only. Files, processes and credentials need their own controls.
- In v0, only HTTP and TLS through the proxy can be allowed.
- In v0, processes of the same user outside every scope count as the owner.
- It does not detect prompt injection. It blocks connections the policy does not allow. Data sent to an allowed
  destination is out of scope.
- Work handed to a daemon outside the task (docker, launchd, a tmux server) runs outside the task.
- No model or remote service takes part in a verdict. No account, no telemetry.

## fx

Since 0.0.5, [fx](https://github.com/vercel-labs/fx) runs approved commands as ordinary host subprocesses
([changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md)). Two ways to use blackice with it:

- **A scope per command.** A small patch to fx's PreToolUse hook, kept in `integrations/fx/` and not part of fx
  upstream, will run every command fx launches as `blackice run`, each with its own scope and receipts.
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
