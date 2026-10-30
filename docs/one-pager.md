# blackice in one page

**Proof of concept, not production.** This page lists only what the entries in [`evidence/`](../evidence/)
show. A row without an entry was not shown and says so.

## What it is

blackice gives network permissions to agent tasks and apps on macOS and Linux. You put it in front of a command:
`blackice run --policy policy.json -- <command>`. The command and every process it starts can then reach only
the destinations the policy allows. By design, the limit is attached before the command runs, nothing inside can widen
it, and every decision is written down. It runs locally, headless, with no account and no telemetry.

## Design

- **Policy**: a small JSON file. Deny everything, allow everything public, or allow a list of names, networks
  and ports (80 and 443 by default). Any mistake in the file stops the run instead of being guessed at.
- **Scope**: the box the policy applies to. The operating system confines the command before its first
  instruction: a Seatbelt sandbox profile on macOS (experimental), a root-owned cgroup with eBPF socket
  programs on Linux. Inside, the only reachable addresses are blackice's own proxy and relay on loopback.
- **Proxy**: checks each requested name against the policy, resolves it itself, and connects only to addresses
  that pass. A program that ignores the proxy has no network at all.
- **Receipts**: one JSON line per decision, with the scope, policy, enforcement point (proxy, kernel, relay,
  control), verdict and reason. Metadata only, no contents.
- **Grants**: the owner can add one host to a running scope for a limited time, from outside. The same command
  from inside the scope fails.
- **fx**: a small declared patch to fx's `PreToolUse` hook runs every command fx launches in its own scope. As a
  fallback, all of fx can run in one scope, reaching its model through a relay that holds the key outside.

## What this proof of concept shows

| Checkpoint | What it shows | Evidence |
|---|---|---|
| P0-01 Policy before execution | A command cannot connect before its scope is armed, even at its first instruction. | macOS: [entry](../evidence/P0-01-policy-before-exec-macos.md). Linux: pending |
| P0-02 Real deny | A direct connection is refused by the OS, and a receiver on another machine sees nothing. Each protocol and address family is stated separately. | macOS, TCP and UDP over IPv4 and IPv6, name lookup, listening and launchd jobs: [entry](../evidence/P0-02-real-deny-macos.md). Linux: pending |
| P0-03 Small explicit allow | One allowed destination works through the proxy; another is refused. | macOS: [entry](../evidence/P0-03-explicit-allow-macos.md). Linux: pending |
| P0-04 Authorized change | The owner widens a scope from outside; the same request from inside fails. | macOS: [entry](../evidence/P0-04-owner-grant-macos.md). Linux: pending |
| P0-05 Bounded grant | The extra access ends at its expiry or when the scope ends. | macOS, expiry: [entry](../evidence/P0-05-grant-expiry-macos.md). Linux: pending |
| P0-07 fx | fx runs with blackice and its commands are confined, with receipts. The fx version is pinned. | macOS, scripted model, full-access mode: [entry](../evidence/P0-07-fx-hook-scripted-macos.md). Real model: pending. Linux: pending |
| P0-08 Second platform | The same checks on the other OS, or the exact blocker. | pending |
| P0-09 Forwardable proof | Evidence entries, a short recording and this page. | pending |
| P0-10 Release gap | The table below. | this page |

P0-06 (faults and recovery) is not part of this proof of concept.

## What is not done yet (release gap)

The first usable release needs all four cells. This proof of concept covers agent tasks only, and "built" below
means the code compiles and its tests pass, not that it was shown working.

| | Agent tasks (task scopes) | Apps (app scopes) |
|---|---|---|
| **macOS** | Built, experimental: a Seatbelt sandbox profile plus the local proxy. Shown on one Mac in the entries above. Not shown yet: launches through `open` or Apple Events refused, fx with a real model. | Built, unsigned: a Network Extension filter. It has never been activated. Needs an Apple Developer ID, a signed Network Extension, tests on a live system, and receipts written through blackice. |
| **Linux** | Built: cgroup v2 with eBPF socket programs, and a small helper installed once by a setup script run with sudo. Not shown yet: no evidence entry so far. | Not built. Identifying an app by its desktop or service group still has to be proven. |

Windows is planned for after macOS and Linux. Nothing is built for it.

Also not in this proof of concept: limits for a whole machine and nested scopes, protocols other than HTTP and
HTTPS through the proxy, observe mode, and recovery after faults.

## Limits

- Network only. Files, processes and credentials need their own controls. On macOS, in the recorded build (58e73cc),
  a command in a scope can read and write the clipboard; refused since claude/run e6dcd3f.
- It does not detect prompt injection. It blocks connections the policy does not allow. Data sent to an allowed
  destination is out of scope.
- With the fx hook, fx itself runs outside the scopes. Its file tools are kept inside the workspace, so
  install blackice and fx outside it (root-owned is best). What fx reads goes to the model provider.
- In v0, any process of the same user that runs outside every scope counts as the owner.
- When a grant ends, the proxy cuts its connections within 200 ms (11 ms measured), but data that already
  reached the program stays readable.
- Work handed to a service outside the scope (launchd, `open`, `systemd-run --user`, Docker) is refused only
  where a test shows it; otherwise it is a stated limit.
- An allowed name on a shared CDN can reach other sites on that CDN through domain fronting inside TLS: the
  proxy checks the TLS server name, not the encrypted request.
- On macOS, a refusal leaves a receipt when the refused program is signed by Apple, such as `curl` or `python3`.
  A program without Apple's signature, such as one you built yourself, is still blocked, but leaves no receipt.
  Programs signed with a Developer ID were not tested.
- Receipts are a local record for diagnosis. Other programs of the same user, and administrators, can change
  them. The scoped command itself is designed not to write them: on macOS that held in probes, without an
  evidence entry yet; on Linux it is not yet tested.

## Build

Zig 0.17, standard library only. One binary, plus a small Linux helper that holds the capabilities needed to
attach the kernel programs. Apache-2.0. Design and requirements: [`docs/specs/`](specs/README.md).
