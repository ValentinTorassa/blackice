---
id: grant
title: Grant
owner: lead
stage: poc
paths:
cases: P0-04, P0-05
depends: policy, proxy, receipts, scope-core
---

# Grant

## What and why

Sometimes a task needs one more destination than its policy allows, for example a package registry halfway
through a build. A grant opens that one host for one scope, for a limited time, and only the owner can give it,
from outside the scope. A program inside the scope cannot grant itself anything: the channel used for grants is
out of its reach. When the time runs out, or the scope ends, the extra access is gone, and both events are
written as receipts.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| grant.R1 | When the owner runs `blackice grant <scope> <host> --for <duration>` outside every scope, blackice shall allow new connections from that scope to that host until the duration ends or the scope ends, whichever comes first. | P0-04, P0-05 |
| grant.R2 | If `blackice grant` is run from inside any scope, it shall fail because it cannot reach the control socket, and no scope's access shall change. | P0-04 |
| grant.R3 | When a grant is accepted, blackice shall raise the scope's policy generation by one, write a `grant` receipt with point `control`, the host and the expiry time, and stamp every later receipt with the new generation. | P0-05 |
| grant.R4 | When a grant expires, blackice shall refuse new connections to that host unless the base policy allows them, raise the generation, and write a receipt for the expiry. | P0-05 |
| grant.R5 | blackice shall state, in the `grant` command's output and in the grant receipt, that ending a grant affects new connections only: a connection opened while the grant was active stays open until it closes or the scope ends. | P0-05 |
| grant.R6 | A grant shall add only a host name or a `*.name` pattern to one scope; the address checks of the policy still apply, and a grant cannot change the mode, the subnets or another scope. | P0-04 |
| grant.R7 | If the grant names a scope that does not exist or has ended, an invalid host, or a duration that is missing, zero or above the maximum, blackice shall refuse it and change nothing. | P0-04 |
| grant.R8 | When a scope ends, blackice shall end all of its grants; a new scope started from the same policy file starts without them. | P0-05 |

## Design

The `blackice` process that runs a scope listens on a control socket, a local file-system socket that only
processes outside the scope can open. `blackice grant` connects to it, asks for one host for a set time, and
gets back the new generation and the expiry. The grant changes what the scope's proxy allows; it does not touch
the operating system rules, which keep allowing only the proxy and relay ports.

**Technical.**

- CLI: `blackice grant <scope> <host> --for <duration>`, for example `--for 10m`. The maximum duration is not
  set yet.
- Control socket: a Unix socket in the scope's state directory, mode 0600. On macOS the scope's Seatbelt
  profile already refuses outbound connections to Unix sockets; on Linux the scope's private mount namespace
  hides the state directory, and abstract Unix sockets are restricted with Landlock where the kernel supports
  it.
- The grant is held in memory by the `blackice` process. Expiry uses its monotonic clock; grants are not
  written to disk and do not survive the process.
- Receipts: `event: grant` with `point: control`, `verdict: allow`, `host`, and the expiry in `detail`; an
  expiry receipt when the time runs out (see [receipts](receipts.md)).
- Owner in v0: any process of the same user that runs outside every scope. This is a declared limit, not a
  security boundary against the user's own software.
- Limits:
  - Revocation covers new connections only. A tunnel the proxy opened during the grant is not cut when it
    ends.
  - No operating system authentication (Touch ID, polkit) yet.
  - A program inside the scope can still leave something behind, such as a script, that the owner later runs
    outside the scope. A grant cannot prevent that.
  - No one-use grants, no grants by port or protocol, no grants that outlive the scope.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Control socket owned by the `blackice` process | lead | todo | |
| `blackice grant` command and in-memory grants with expiry | lead | todo | |
| Grant, expiry and generation in receipts | lead | todo | |
| Show on macOS that a scoped process cannot reach the control socket | lead | todo | |
| Hide the control socket from Linux scopes | codex-linux | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|

## Terms

grant, owner, control socket, scope, policy generation, receipt, CONNECT proxy, Seatbelt, mount namespace,
Landlock, revocation
