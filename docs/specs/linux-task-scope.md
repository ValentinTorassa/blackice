---
id: linux-task-scope
title: Linux task scope
owner: codex-linux
stage: poc
paths: src/linux/, scripts/linux-setup.sh, scripts/linux-teardown.sh
cases: P0-01, P0-02, P0-03, P0-04, P0-08, P0-09
depends: policy, proxy, receipts
---

# Linux task scope

## What and why

On Linux, `blackice run` puts the command in its own kernel group of processes (a cgroup) before it starts.
Small programs attached to that group inside the kernel refuse every connection the group tries to open,
except to blackice's own proxy and relay on this machine, and each refusal is written down as a receipt. Name
lookups that would go around the proxy are cut off too, because the command cannot see the system resolver's
sockets. Setting this up needs root once: Valen runs a short setup script with sudo, and a second script removes
everything again. After that, scopes start without sudo, and a command inside a scope cannot move itself out or
loosen its own rules.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| linux-task-scope.R1 | When `blackice run` starts a command on Linux, blackice shall place it in the scope's own cgroup, with the scope's kernel rules already attached, before the command's first instruction. | P0-01 |
| linux-task-scope.R2 | While a command runs in a Linux task scope, the kernel shall refuse every connection and datagram that the command or any descendant attempts, except TCP over IPv4 to the scope's proxy and relay ports on 127.0.0.1. This is qualified separately for TCP and for connected and unconnected UDP, each over IPv4 and IPv6. | P0-02, P0-03 |
| linux-task-scope.R3 | When the kernel refuses a connection or datagram from a scope, blackice shall write one receipt with enforcement point `kernel` and the destination address and port, through the scope's single receipt writer. If kernel events are lost, blackice shall count the loss and report it in `scope_end`; a lost event never lets traffic through. | P0-02, P0-09 |
| linux-task-scope.R4 | While a command runs in a Linux task scope, a name lookup that does not go through the proxy shall fail: the system resolver's Unix sockets shall be hidden from the scope, and DNS traffic to any address shall be refused. | P0-02 |
| linux-task-scope.R5 | If a process inside a scope tries to move itself or another process out of the scope's cgroup, or to change the scope's kernel rules, the attempt shall fail and the rules shall stay in force. | P0-02 |
| linux-task-scope.R6 | If a process inside a scope asks a local service manager to start a process for it (the user's systemd instance, for example `systemd-run --user`, or Docker), the request shall fail. | P0-02 |
| linux-task-scope.R7 | When blackice starts a command on Linux, the command shall not inherit any network socket from blackice. | P0-02 |
| linux-task-scope.R8 | If the helper is not installed, the kernel lacks a feature the scope needs (cgroup v2, cgroup socket-address programs, the ring buffer), or any setup step fails, blackice shall refuse to run the command and say which piece is missing. | P0-01 |
| linux-task-scope.R9 | When a scope ends, blackice shall remove its cgroup and its kernel programs, and report any process from the scope that is still running. | - |
| linux-task-scope.R10 | The setup script shall be the only step that needs root. After it runs, a member of the configured group can start scopes without sudo, and the teardown script shall remove everything the setup installed. | P0-01 |
| linux-task-scope.R11 | A process inside a scope shall not be able to connect to a Unix socket created outside it: path-based sockets are hidden or refused, and abstract sockets are scoped with Landlock where the kernel supports it. | P0-04 |
| linux-task-scope.R12 | When the same policy and the same test destinations run in a Linux and a macOS task scope, blackice shall reach the same verdict for each destination. The receipts may differ only in the enforcement point. | P0-08 |
| linux-task-scope.R13 | If a process inside a scope tries to open a raw socket, a socket in an unsupported family, or an IPv4 or IPv6 socket with a protocol other than TCP or UDP (for example SCTP or ICMP "ping" sockets, which the cgroup socket hooks do not fully cover), to enter another network namespace, or to send through io_uring, blackice shall refuse it. | P0-02 |
| linux-task-scope.R14 | A process inside a scope shall not be able to accept connections from outside the scope: `bind`, `listen` and `accept` on network sockets shall be refused. | P0-02 |

## Design

Linux can label every process with the cgroup it belongs to, and children inherit that label. blackice creates
one cgroup per scope in a part of the tree that only root controls, so neither the command nor the user's own
service manager can move processes out of it. A small privileged helper does the root-only work: it starts the
command paused, puts it in the scope's cgroup, attaches the kernel programs that decide each connection, and
only then lets it run. Those programs allow only connections to the proxy and the relay; the proxy decides names
and addresses using the policy. Before the command runs, it also gets a private view of the filesystem in which
the system resolver's sockets do not exist, so it cannot ask a system service to look names up for it.

**Technical.**

- Cgroups: `/sys/fs/cgroup/blackice/<scope>`, created by the helper and owned by root, outside
  `user@UID.service`. Under the user's delegated tree the user owns the common ancestor, so a same-user process
  could write its own PID into a sibling cgroup, and `systemd-run --user --scope` could move it.
- Launch order: the helper forks its own paused child (it never takes a process ID from its caller), holds it
  through a pidfd, creates the cgroup, attaches the programs, sets up the child's containment, and releases it
  only after all of that is armed. Any failure kills the held child (R1, R8). Death of the parent, the helper or
  the workload, and cleanup of what the scope owns, are handled explicitly.
- Kernel rules: cgroup socket-address eBPF programs on `connect4`, `connect6`, `sendmsg4` and `sendmsg6`. They
  decide at the socket call, before any packet exists, so connected and unconnected UDP and IPv6 are covered
  by the same hooks. Only IPv4 TCP to `127.0.0.1:<proxy>` and `127.0.0.1:<relay>` passes. No host firewall rules
  are changed.
- Receipts: each refusal is reported through a per-scope BPF ring buffer to the blackice process, the only writer
  of the scope's `receipts.jsonl` (see [receipts](receipts.md)). Lost events are counted separately.
- Helper: a small static binary installed by `scripts/linux-setup.sh` with file capabilities (not setuid) and
  executable only by a configured group. It needs `CAP_BPF`, `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE` and
  `CAP_CHOWN`; neither blackice nor the workload gets any of them. `scripts/linux-teardown.sh` removes the
  helper, the cgroup subtree and the programs.
- DNS gating and local services: a private mount namespace for the child hides `/run/systemd/resolve`
  (resolved's varlink socket), the system D-Bus socket (`org.freedesktop.resolve1`), avahi's and nscd's sockets,
  the user's session bus and the Docker socket (R6). glibc then falls back to the servers in `resolv.conf`,
  which the kernel programs refuse.
- Other channels: Landlock scopes abstract Unix sockets and signals where the kernel supports it (ABI 6), and a
  seccomp filter refuses creating Unix sockets, raw sockets, other socket families, protocols other than TCP
  and UDP (SCTP has no cgroup socket-address hook, and an unconnected send on an ICMP ping socket skips
  `sendmsg4/6`), `bind`, `listen` and `accept`, new network namespaces and io_uring. The blackice state
  directory is read-only inside the scope. Two processes inside the same scope can still talk to each
  other over a socket pair.
- Why not nftables: matching packets by cgroup lets packets the kernel cannot attribute fall through the match.
  Admission at the socket call avoids that path. nftables with NFLOG was the first plan and stays a documented
  alternative.
- The current code (`src/linux/backend.zig`) is a placeholder: it reports `backend_unavailable` and refuses to
  run any command, so blackice never runs a command unconfined on Linux.
- Limits:
  - In v0 only the proxy and relay are reachable, so every allowed destination goes through the proxy. Protocols
    that cannot use an HTTP proxy cannot be allowed yet.
  - Containers and other network namespaces are refused, not supported.
  - The proxy's own upstream sockets are outside the scope's cgroup; their limits are the proxy's job.
  - No general claim that a same-user process outside the scope cannot interfere.
  - The state directory is a read-only mount inside the scope. That does not cover every path to the same
    files (another process's `/proc/<pid>/root`, hard links made before the scope), so it is not a
    tamper-proof record. The policy is kept in memory, never re-read from that directory.
  - The setup script installs the helper only if its SHA-256 matches the expected value given to it, checked on
    the root-owned copy. The helper is built stripped, without Zig's crash handler.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Placeholder backend that refuses to run commands | lead | done | |
| Backend design: socket-address admission programs instead of nftables | codex-linux | done | |
| Privileged helper: fork a paused child, hold it by pidfd, enroll it in the scope cgroup, release when armed | codex-linux | doing | |
| `blackice-linux-helper` build target in build.zig | codex-linux | doing | |
| cgroup eBPF programs on connect4, connect6, sendmsg4 and sendmsg6 | codex-linux | doing | |
| Ring buffer reader that reports refusals to the receipt writer, with a lost-event count | codex-linux | todo | |
| Private mount namespace that hides resolver and daemon sockets | codex-linux | doing | |
| Landlock scoping and seccomp filter | codex-linux | doing | |
| `scripts/linux-setup.sh` and `scripts/linux-teardown.sh` | codex-linux | doing | |
| Security review of the setup script before it runs | security | doing | |
| Run the setup script with sudo, once it is reviewed | valen | todo | waits for: the scripts and their review |
| Fixtures: immediate connect, fork and exec, TCP and both UDP modes on IPv4 and IPv6, migration, `systemd-run --user`, Docker socket, raw sockets, io_uring, `ping`, an SCTP connect, an unconnected ICMP `sendto`, `bind` and `listen`, DNS paths (`getent hosts`, `resolvectl query`, `busctl call org.freedesktop.resolve1`) | codex-linux | doing | |
| End-to-end kernel deny with receipts, an off-host receiver that sees nothing per protocol and family, and an evidence entry | codex-linux | todo | |
| docs/linux.md | codex-linux | todo | |
| docs/threat-model.md | codex | done | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| linux-task-scope.R4 | probe | Name lookup from a network namespace with only loopback (bubblewrap), Debian 13, kernel 6.12, without blackice code | TCP to a public address was unreachable, but `example.com` still resolved through systemd-resolved's world-writable Unix socket. With a tmpfs over `/run/systemd/resolve`, resolution failed. A network namespace alone does not close DNS |
| linux-task-scope.R2 | probe | fx 0.0.16 in the same kind of network namespace, scripted local model, stand-in proxy | A direct `curl` from a tool could not resolve the host; through the stand-in proxy it arrived as `CONNECT example.com:443`. Uses a network namespace, not cgroup rules, so it shows the proxy route, not the kernel rule |

## Terms

task scope, cgroup v2, eBPF, seccomp, mount namespace, Landlock, DNS gating, DNS, CONNECT proxy, relay, receipt, policy, backend, nftables
