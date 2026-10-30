---
id: scope-core
title: Task scope core
owner: lead
stage: poc
paths: src/main.zig, src/core/scope.zig, src/core/backend.zig
cases: P0-01, P0-02, P0-09, P0-10
depends: policy, receipts, proxy
---

# Task scope core

## What and why

`blackice run` puts one command, and every process it starts, inside a task scope. It reads the policy
first, starts the scope's proxy, and only then hands the command to the operating system's confinement for
this platform. The command never runs for a moment without that confinement: if this platform has no working
confinement yet, blackice refuses to run it and says so. When the command ends, the scope ends with it and
blackice exits with the command's own status, so it can sit in front of any command in a script.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| scope-core.R1 | When `blackice run --policy FILE -- CMD...` is invoked, blackice shall load and check the policy before it creates the scope; if the policy is refused, it shall exit non-zero without starting CMD. | P0-01 |
| scope-core.R2 | blackice shall start CMD only after the platform backend has confined it, so that a connection CMD attempts at its very first instruction is already subject to the scope. | P0-01 |
| scope-core.R3 | If this platform has no enforcing backend, blackice shall refuse to run CMD, print the reason, write a `warning` receipt with reason `backend_unavailable`, and exit non-zero. It shall never run a command unconfined. | P0-10 |
| scope-core.R4 | When a scope is created, blackice shall give it a new identifier (`s-` followed by 8 hex digits) and a state directory holding the exact policy bytes and the scope's `receipts.jsonl`. | P0-09 |
| scope-core.R5 | blackice shall confine CMD and every process it starts so that they can open network connections only to the loopback ports of the scope's own proxy and, when present, its relay. | P0-02 |
| scope-core.R6 | When CMD starts, blackice shall set `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY`, in upper and lower case, to the scope's proxy address, and remove `NO_PROXY` and `no_proxy`. | P0-03 |
| scope-core.R7 | When the scope starts and ends, blackice shall write a `scope_start` and a `scope_end` receipt; `scope_end` carries CMD's exit status and the number of receipts that could not be written. | P0-09 |
| scope-core.R8 | When CMD ends, blackice shall stop the scope's proxy and relay and exit with CMD's exit code, or 128 plus the signal number if CMD was killed by a signal. | P0-01 |
| scope-core.R9 | When `--name N` is given, blackice shall record N in the `scope_start` receipt as a label only; a name never selects or widens a policy. | P0-09 |
| scope-core.R10 | blackice shall make the scope's state directory read-only, or hidden, for the command and every process it starts, and shall load the policy into memory once, never re-reading it from that directory. | P0-04 |

## Design

`blackice run` is one process that owns the whole scope: it reads the policy, creates the scope directory,
opens the receipt log, starts the proxy (and the relay when asked), and asks the platform backend to launch the
command already confined. Everything that decides or records stays outside the command. The backend's only
job is to make sure the command and its children cannot reach the network except through the scope's own
loopback ports; names and addresses are then decided by the proxy.

**Technical.**

- CLI: `blackice run --policy FILE [--name N] -- CMD...`. Today the binary implements `version` and
  `policy check FILE`; `run` is being built.
- Scope identifier: `s-` + 8 random hex digits (`src/core/scope.zig`).
- State directory: `$XDG_STATE_HOME/blackice/scopes/<id>/` when `XDG_STATE_HOME` is an absolute path,
  otherwise `~/.local/state/blackice/scopes/<id>/`. It holds `policy.json` (the exact bytes the scope started
  with) and `receipts.jsonl`.
- Backend contract (`src/core/backend.zig`): the core passes a `LaunchSpec` with the scope id, argv, the
  environment (already carrying the proxy variables), `allowed_loopback_ports`, the state directory
  (`state_dir`, which the backend makes read-only or hidden inside the scope) and the receipt log. The backend
  must confine the command before it runs and returns its exit (`exited`, `signal` or `other`).
  `BackendUnavailable` means the command was not run. Changing this contract is a recorded change between
  owners.
- Backends: macOS uses a Seatbelt profile through `sandbox-exec` ([macos-task-scope](macos-task-scope.md));
  Linux uses a root-owned cgroup with nftables rules ([linux-task-scope](linux-task-scope.md)). Until the
  Linux backend lands, `run` on Linux refuses.
- Lifecycle in v0: requested, checked, confined, running, ended. Not in v0: policy updates other than grants,
  a degraded state with recovery, draining, and nested scopes.
- Limits:
  - Clients that ignore the proxy variables cannot connect at all: they fail closed, they are not let
    through.
  - Work handed to a service outside the scope (a container daemon, launchd, `systemd-run --user`) runs
    outside the scope. Each platform spec lists what it blocks and what it does not.
  - The state directory is in the user's home and only the blackice process writes it; inside the scope it is
    read-only or hidden. Other processes of the same user outside every scope can still change it, so
    receipts are a record for diagnosis, not tamper-proof evidence.
  - What happens to processes still running after CMD exits is not defined yet (see Tasks).

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Scope identifier and state directory | lead | done | |
| Backend contract between the core and the platform backends | lead | done | |
| Linux placeholder that refuses to run and writes a `backend_unavailable` receipt | lead | done | |
| `blackice run`: arguments, policy load, scope creation, launch, exit status | lead | doing | |
| Write the policy bytes into the state directory | lead | todo | |
| State directory read-only inside the scope on macOS (`state_dir` in the launch contract) | lead | todo | |
| State directory read-only or hidden inside the scope on Linux | codex-linux | doing | |
| Proxy variables in the command's environment | lead | todo | |
| `scope_start` and `scope_end` receipts, with the failed-write count | lead | todo | |
| Decide and document what happens to processes left running after CMD exits | lead | todo | |
| Create each scope's state directory exclusively (0700), with a new id on a clash | lead | done | |
| Linux enforcing backend behind the same contract | codex-linux | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| scope-core.R4 | test | `zig build test`, src/core/scope.zig: "newId", "create" | Identifier format, and a new owner-only directory per scope. 21/21 passed at 99e2f4e (PR #1), Zig 0.17.0, Linux x86_64 |

## Terms

task scope, scope, policy, receipt, backend, state directory, loopback, proxy variables, Seatbelt,
sandbox-exec, cgroup v2, nftables, exit status
