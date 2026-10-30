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
| P0-01 Policy before execution | A command cannot connect before its scope is armed, even at its first instruction. | pending |
| P0-02 Real deny | A direct connection is refused by the OS, and a receiver on another machine sees nothing. Each protocol and address family is stated separately. | pending |
| P0-03 Small explicit allow | One allowed destination works through the proxy; another is refused. | pending |
| P0-04 Authorized change | The owner widens a scope from outside; the same request from inside fails. | pending |
| P0-05 Bounded grant | The extra access ends at its expiry or when the scope ends. | pending |
| P0-07 fx | fx runs with blackice and its commands are confined, with receipts. The fx version is pinned. | pending |
| P0-08 Second platform | The same checks on the other OS, or the exact blocker. | pending |
| P0-09 Forwardable proof | Evidence entries, a short recording and this page. | pending |
| P0-10 Release gap | The table below. | this page |

P0-06 (faults and recovery) is not part of this proof of concept.

## What is not done yet

The first usable release needs all four cells. This proof of concept covers agent tasks only.

| | Agent tasks (task scopes) | Apps (app scopes) |
|---|---|---|
| **macOS** | Experimental: Seatbelt profile plus the local proxy. | Network Extension filter: code being built, unsigned. It cannot run until it is signed with an Apple Developer ID. |
| **Linux** | cgroup v2 with eBPF socket programs, installed once by a setup script run with sudo. | Not built. Identifying an app by its desktop or service group still has to be proven. |

Also not in this proof of concept: limits for a whole machine and nested scopes, protocols other than HTTP and
HTTPS through the proxy, observe mode, and recovery after faults.

## Limits

- Network only. Files, processes and credentials need their own controls.
- It does not detect prompt injection. It blocks connections the policy does not allow. Data sent to an allowed
  destination is out of scope.
- In v0, any process of the same user that runs outside every scope counts as the owner.
- Work handed to a service outside the scope (launchd, `open`, `systemd-run --user`, Docker) is refused only
  where a test shows it; otherwise it is a stated limit.
- An allowed name on a shared CDN can reach other sites on that CDN through domain fronting inside TLS: the
  proxy checks the TLS server name, not the encrypted request.
- Receipts are a local record for diagnosis. Other programs of the same user, and administrators, can change
  them. The scoped command itself is designed not to write them: on macOS that held in probes, without an
  evidence entry yet; on Linux it is not yet tested.

## Build

Zig 0.17, standard library only. One binary, plus a small Linux helper that holds the capabilities needed to
attach the kernel programs. Apache-2.0. Design and requirements: [`docs/specs/`](specs/README.md).
