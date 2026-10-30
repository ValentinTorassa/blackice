# blackice

Network permissions for apps and agent tasks on macOS and Linux. Native and headless.

> **Status: proof of concept, not production.** Nothing here is verified yet. A capability is listed as working
> only when a recorded test backs it; see [`evidence/`](evidence/).

## Design

- A **task scope** wraps a command and every process it starts:
  `blackice run --policy policy.json -- <command>`. The policy is attached before the command runs.
- An **app scope** applies a policy to an app already on the machine.
- A **host ceiling** sits over every scope. Nested scopes can only narrow.
- Deny by default, with allow lists for domain names and networks. DNS is part of the boundary.
- Only the owner can widen a scope, from outside it, for a limited time.
- Each decision is written as a JSON line with the scope, the policy generation, the destination and a stable
  reason code.

The CLI and the policy schema are not frozen yet.

## Platforms (planned)

| | Apps | Agent tasks |
|---|---|---|
| macOS | Network Extension (signed) | Seatbelt session with a local proxy (experimental) |
| Linux | Chosen after a spike | cgroup v2 with nftables or eBPF |

## Limits

- Network only. Files, processes and credentials need their own controls.
- It does not detect prompt injection. It blocks connections the policy does not allow. Data sent to an allowed
  destination is out of scope.
- Work handed to a daemon outside the task (docker, launchd, a tmux server) runs outside the task.
- No model or remote service takes part in a verdict. No account, no telemetry.

## fx

Since 0.0.5, [fx](https://github.com/vercel-labs/fx) runs approved commands as ordinary host subprocesses
([changelog](https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md)). `blackice run -- fx` is designed to put
fx and everything it starts in one task scope, without changes to fx. A scope per tool call needs a launch hook in
fx and is future work.

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
