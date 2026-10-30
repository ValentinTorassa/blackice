---
id: grant
title: Grant
owner: lead, network
stage: poc
paths: src/control/, src/proxy/grants.zig
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
| grant.R5 | When a grant ends, the proxy shall close every connection it opened under that grant and write a `grant_expired` receipt. If it cannot arm the timer that does this, it shall refuse the connection instead of opening it without a limit. | P0-05 |
| grant.R6 | A grant shall add only a host name or a `*.name` pattern to one scope; the address checks of the policy still apply, and a grant cannot change the mode, the subnets or another scope. | P0-04 |
| grant.R7 | If the grant names a scope that does not exist or has ended, an invalid host, or a duration that is missing, zero or above the maximum, blackice shall refuse it and change nothing. | P0-04 |
| grant.R8 | When a scope ends, blackice shall end all of its grants; a new scope started from the same policy file starts without them. | P0-05 |
| grant.R9 | When a control connection arrives, blackice shall check its peer: the same user ID (`SO_PEERCRED` on Linux, `getpeereid` on macOS) and, on Linux, a cgroup outside `/sys/fs/cgroup/blackice/`. Any other peer shall be refused with a receipt. | P0-04 |
| grant.R10 | blackice shall measure a grant's duration on a clock that a change of the system time cannot move back (a monotonic clock), and use wall-clock time only to print the expiry. | P0-05 |

## Design

The `blackice` process that runs a scope listens on a control socket, a local file-system socket that only
processes outside the scope can open. `blackice grant` connects to it, asks for one host for a set time, and
gets back the new generation and the expiry. The grant changes what the scope's proxy allows; it does not touch
the operating system rules, which keep allowing only the proxy and relay ports.

**Technical.**

- CLI: `blackice grant <scope> <host> --for <duration>`, for example `--for 10m`; at most one hour.
- Protocol on the control socket: one JSON line in, one out, then the connection closes. `grant` (host, seconds,
  1 to 3600) and `revoke` (host). Unknown fields, IP literals and other durations are refused, each with a
  receipt (`peer_not_owner`, `bad_request`, `invalid_duration`, `invalid_host`). Granting a host again extends
  the grant, never shortens it.
- Control socket: a Unix socket in the scope's state directory, mode 0600.
  - macOS: the profile's outbound deny covers Unix-socket connections, and the profile denies writes to the
    state directory. That the scope cannot reach the control socket still needs its own test.
  - Linux: the scope's seccomp filter refuses `socket(AF_UNIX, ...)` altogether; only `socketpair` works inside,
    so the scope cannot open a connection to the control socket. The state directory stays visible, read-only.
    Abstract Unix sockets are also scoped with Landlock where the kernel supports it.
  - Every control connection is checked for its peer (R9), so one leaked descriptor or a missed rule is not
    enough to accept a grant from inside a scope.
- The grant is held in memory by the proxy, as a name or `*.name`, never an IP literal. It never lifts a port or
  address refusal. Grants are not written to disk and do not survive the process.
- Lifetimes run on the boot clock, not the wall clock (R10). At expiry or on revoke, a watchdog closes the
  `CONNECT` tunnels and plain HTTP exchanges opened under the grant (R5); if the watchdog cannot start, the
  connection is refused instead of running without a time limit.
- Receipts: `event: grant` with `point: control`, `verdict: allow`, `host`, and the expiry in `detail`; an
  expiry receipt when the time runs out (see [receipts](receipts.md)).
- Owner in v0: any process of the same user that runs outside every scope. This is a declared limit, not a
  security boundary against the user's own software.
- Limits:
  - No operating system authentication (Touch ID, polkit) yet.
  - A program inside the scope can still leave something behind, such as a script, that the owner later runs
    outside the scope. A grant cannot prevent that.
  - No one-use grants, no grants by port or protocol, no grants that outlive the scope.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| In-memory grants in the proxy (names only), with expiry that closes tunnels | network | done | |
| Control socket: one-line JSON protocol, peer check, receipts (`src/control/`) | network | done | |
| Grants on the boot clock | network | done | |
| Refuse the connection when the expiry timer cannot start | network | done | |
| Close plain HTTP requests at grant expiry or revoke | network | done | |
| `blackice grant` and `blackice revoke` commands (PR #7) | lead | done | |
| Grant, expiry and generation in receipts | lead | todo | |
| Show on macOS that a scoped process cannot reach the control socket | lead | done | |
| Refuse Unix sockets inside Linux scopes (seccomp), so the control socket is out of reach | codex-linux | doing | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| grant.R1, grant.R2, grant.R6, grant.R8 | entry | [P0-04 macOS](../../evidence/P0-04-owner-grant-macos.md) | macOS 27.0.1 arm64, SIP on, claude/run 58e73cc, Zig 0.17.0, one run, PR #10 (not merged). Self-grant from inside refused (PermissionDenied, no grant receipt); owner grant from outside let github.com through (`granted`); www.github.com still refused; no socket after the scope ended. The generation stayed 1 after the grant, so grant.R3 is not shown |
| grant.R1, grant.R5, grant.R6, grant.R7, grant.R9 | test | `zig build test`, src/proxy/test.zig: "a grant allows a refused name until it expires, and expiry closes the tunnel", "revoking a grant closes the tunnels opened under it", "a grant whose watchdog cannot start is refused, never unbounded", "grant expiry also cuts a plain HTTP exchange in flight"; src/control/test.zig: "grant and revoke from outside the scope", "requests are parsed strictly and bounded", "peerCred reports this process's uid and pid for a local peer", "a peer that never sends a full line is disconnected" | 65/65 passed at 986645a (PR #4), Zig 0.17.0, Linux x86_64, six runs, real loopback sockets, fixed resolver, stand-in upstreams; no network. The earlier hang in a control test did not recur. Same-user peers only; no test from inside a real scope yet |
| grant.R1, grant.R2, grant.R6, grant.R8 | probe | Reported by the lead: `blackice run` (PR #7, 61ffe84) on macOS 27.0.1 (26A434), arm64, SIP on, ReleaseSafe | github.com refused; `blackice grant` from inside the scope refused by the OS (PermissionDenied); the owner's grant from outside let github.com through (`granted`, rule `grant:github.com`) while www.github.com stayed refused; the socket was gone after the scope ended. No evidence entry yet |

## Terms

grant, owner, control socket, scope, policy generation, receipt, CONNECT proxy, Seatbelt, seccomp, mount namespace,
Landlock, revocation
