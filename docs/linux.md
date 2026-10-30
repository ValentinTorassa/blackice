# Linux task scopes

This backend is an experimental managed-command implementation. It is not an app/host firewall. An actual
installed-helper run on Debian 13 x86_64, kernel 6.12.113, recorded
[policy-before-exec](https://github.com/ValentinTorassa/blackice/blob/aa5a048e1762a0c3c3c56cc8e7a0bf6c4473b0f8/evidence/P0-01-policy-before-exec-linux.md)
and [off-host TCP/UDP denial](https://github.com/ValentinTorassa/blackice/blob/aa5a048e1762a0c3c3c56cc8e7a0bf6c4473b0f8/evidence/P0-02-real-deny-linux.md)
with immediate and double-forked senders over IPv4 LAN and IPv6 Tailscale. Those entries identify the exact
launcher/helper hashes and test limits; a passing build or namespace test alone is not P0-02 evidence.

## Boundary

The core starts its proxy outside the workload and supplies its loopback ports. The helper attaches four
`BPF_PROG_TYPE_CGROUP_SOCK_ADDR` programs to a new, root-owned cgroup under `/sys/fs/cgroup/blackice`:

| Operation | Admission |
| --- | --- |
| IPv4 TCP connect | Only `127.0.0.1` and an explicitly supplied port |
| IPv6 TCP connect, including mapped addresses | Denied |
| IPv4/IPv6 UDP connect | Denied |
| IPv4/IPv6 unconnected UDP sendmsg/sendto | Denied |
| Raw, ping, SCTP, MPTCP and other socket protocols/families | Socket creation refused by seccomp |
| Filesystem and abstract Unix socket creation | Refused by seccomp; intra-workload socketpair remains available |
| Bind/listen, namespace creation, ptrace, BPF, io_uring | Refused by seccomp |

These are implementation semantics; the evidence above covers the TCP/UDP cases it explicitly lists.
IPv6 and UDP have no allow path.
Names and allowed remote destinations belong to the external proxy; the kernel does not resolve names.
Direct DNS cannot use UDP or arbitrary TCP. Resolver and service-manager IPC is also restricted.
Neither nftables rules nor unrelated host networking configuration is modified.

The setup grants `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_NET_ADMIN` and `CAP_BPF` only to a small, static,
stripped helper. The workload and `blackice` receive no file capabilities. The helper creates its own child;
there is no arbitrary-PID attach API. It pins process lifetimes with pidfds, verifies enrollment and all four
attachments, and holds the child behind a pipe handshake until containment is armed.

Before exec, the child closes all unexpected descriptors, drops host capabilities, creates private user/mount
namespaces, and waits while its parent writes the one-ID uid/gid maps through that child's proc directory.
The child stays non-dumpable throughout: its own mapping files become root-owned, so the parent uses its
existing `CAP_DAC_OVERRIDE` to open them. The PID comes only from the helper's own fork, remains unreaped
and pidfd-pinned, and the mapping values are the caller's uid/gid. A failed or partial mapping never releases
the child. It then masks `/run`, `/var/run`, `/tmp` and `/var/tmp`. The caller's numeric uid/gid and working
directory are preserved, reopening cwd through the new mounts. When cwd is below `/tmp` or `/var/tmp`, only
that directory and its descendants are restored from a pinned descriptor. Explicitly protected objects and
the state root outside cwd are also restored at their own paths; unrelated temporary siblings and parent
contents remain hidden. Run from the project root if commands need its whole tree. Cwd equal to `/tmp` or
`/var/tmp`, or anywhere under `/run`, is refused.
The complete blackice state root, including every scope's
receipts, policy copies and control sockets, is recursively mounted read-only.
Landlock ABI 6 scopes abstract Unix sockets and signals. Finally, all capabilities are dropped and an
inherited seccomp filter and `no_new_privs` prevent reacquiring privilege. Socket-backed standard input,
output or error is rejected rather than inheriting an outside socket's cgroup attribution.

The core supplies the canonical absolute state root through `LaunchSpec.state_dir`; a missing or invalid
path refuses launch. The standalone receiver probe protects its receipt directory instead.
The seccomp prohibition on Unix socket creation prevents connections to `control.sock`; a read-only mount
alone does not prevent connecting to an existing socket.

The helper parent must be able to open its child's proc directory to install the ID maps. A `/proc` mount
with `hidepid=2` or `hidepid=invisible` that denies this access makes launch fail closed at
`child_id_mapping`. The helper does not request `CAP_SYS_PTRACE` to override that restriction.

## Protected files and state ancestors

`LaunchSpec.protected_paths` supplies the executable, policy and `--protect` files, including symlink entries
on the way to their resolved targets. The helper pins each object with `openat2`, refusing intermediate
symlinks and magic links. It bind-mounts the pinned file or final symlink node read-only, with `nosuid` and
`nodev`. Protected executables can still run. Every ancestor of these objects and of the state root becomes
a mount point, so renaming, removing or replacing an ancestor fails with `EBUSY`. Ancestors stay writable:
creating, editing, renaming and removing neighboring files still works.

A plain read-only bind leaves existing hard links and alternate mounts writable. This implementation
refuses protected files or symlinks with a link count other than one (`ProtectedFileHasHardLinks`), and
requires exactly one initial mount-table entry for each filesystem containing protected objects or the
state root (`ProtectionFilesystemHasAliases`). This is deliberately conservative: multiple mounts of a
filesystem, including otherwise legitimate subvolume arrangements, may refuse launch. The limits are 48
protected paths, 256 distinct ancestors and a 64 KiB mount table; exceeding a limit refuses before exec.
Standard descriptors cannot be directories or refer to a protected inode or a file within the state root;
an old open descriptor would otherwise retain access through its original mount.

These mounts are applied after dropping host capabilities, in the child's private namespaces. The launch
uses helper protocol v2; an older installed helper refuses it before running the command, and the core
records `linux_helper_upgrade_required`. There is no fallback that omits protected paths. This requires a
fresh reviewed helper build and owner installation; the earlier a6a9a95 helper cannot honor this contract.

## Build and install

Required: Zig 0.17.0, Linux with unified cgroup v2, cgroup BPF socket-address hooks and ring buffers, user/mount
namespaces, pidfds, `cgroup.kill`, `openat2`, `statx` mount IDs, `mount_setattr`, seccomp and Landlock ABI 6. Linux 6.12 is the initial target;
version alone does not prove the required kernel configuration. The helper refuses missing capabilities.
Source supports x86_64 and aarch64; only x86_64 has been exercised locally so far.

Tested on Debian 13 (kernel 6.12), without Ubuntu's AppArmor user-namespace restriction. Ubuntu introduced
`kernel.apparmor_restrict_unprivileged_userns` in 23.10 and enabled it by default in
[24.04 and later](https://documentation.ubuntu.com/release-notes/24.04/#unprivileged-user-namespace-restrictions);
the [23.10 release notes](https://documentation.ubuntu.com/release-notes/23.10/#security-improvements)
explicitly describe it as disabled by default. With that setting at `1` and no suitable AppArmor profile,
scopes are expected to fail closed at `child_containment`: the helper's child drops its capabilities before
`unshare` and counts as unprivileged, so the namespace's mount operations are denied. The namespace-mount
failure was reproduced in Ubuntu 26.04 CI; an installed-helper run on Ubuntu remains unverified.
An AppArmor profile installed by setup would be a separate privileged change requiring security review.
Current setup does not install such a profile or change host sysctls.

Build as the normal user:

```sh
zig build
zig build test
zig build linux-probe
./scripts/linux-build-helper.sh
```

The helper always uses ReleaseSafe with stripped debug information and an explicit `x86_64-linux` or
`aarch64-linux` target with the baseline CPU. Both `zig build` and the separate helper script use that target,
so host CPU features do not change the reviewed artifact. Its panic path does not symbolize or read source
files, and Zig's segmentation-fault handler is disabled. The helper script prints the target and binary's
SHA-256. Before installation, have the privileged helper and scripts reviewed, and compare that hash with an
independent build of the reviewed commit.

The owner runs the reviewed script manually, supplying that expected hash:

```sh
sudo ./scripts/linux-setup.sh USER EXPECTED_SHA256
```

Setup verifies a root-owned private copy against the expected hash before granting capabilities. It installs
`/usr/local/libexec/blackice-linux-helper` as root, executable only by root and the selected user's primary
group. Both the staged and installed files must have exactly mode 0750 and the four required effective and
permitted capabilities, with no inheritable capabilities. Setup records the installation namespaces in
`/etc/blackice-linux/namespaces` (root:root 0644, directory 0755), and creates the cgroup parent as root:root
0700. The Bash scripts use strict error handling, absolute command paths and an action trace. No sudoers
entry, daemon, dependency download, sysctl change or firewall flush is installed.
Run commands as the normal user after setup. Repeat setup after a reboot; cgroups are not persistent.

`blackice run --policy examples/agent.json -- COMMAND ARGUMENTS` uses this backend through the shared
launcher. The core starts the scope's proxy and control socket outside the cgroup and supplies only the proxy
port; `--relay` adds the relay's port. All service and kernel receipts use the same core-owned log. With
`--relay`, the unprivileged launcher replaces stdin with `/dev/null` before executing the helper, so the
command cannot seek back through the provider-key input. Ordinary runs inherit non-socket stdin.

Recovery is an explicit owner operation:

```sh
sudo ./scripts/linux-teardown.sh
```

It disables new helper executions, terminates only blackice scope cgroups and removes only blackice's
helper/configuration, including root-owned setup staging files left by an uncatchable interruption. The
reserved temporary names are `blackice-linux-helper.XXXXXX` and `namespaces.XXXXXX` in their installation
directories. It is safe to repeat. A populated or stuck cgroup retains its attached policy;
teardown refuses to remove that boundary and leaves new launches disabled until owner recovery. Never
detach programs from a live scope as a shortcut.

## Receipts and lifetime

Kernel admission refusals enter a per-scope 64 KiB ring buffer. They carry the destination, port, protocol,
hook and kernel-observed process ID. The helper forwards fixed-size, versioned records on a private pipe;
only the blackice process writes JSON receipts. `kernel_drop` with `point: kernel` means the socket operation
was refused before transmission; it is not a claim that a packet reached an nftables hook. Seccomp refusals
at socket creation, including `ping`, SCTP and ICMP `sendto` attempts, return `EPERM` without an individual
`kernel_drop` receipt. No socket-create BPF hook is installed. Protected-path mutation failures return the
kernel's errno (usually `EROFS`, `EBUSY` or `EXDEV`); they do not each generate a receipt. Containment setup
failures produce a kernel warning receipt and prevent command execution.

Ring overflow increments an independent atomic loss counter. Nonblocking receipt-pipe overflow is counted
separately by the helper; their total is reported at shutdown. Neither kind of loss changes a deny verdict.
An abrupt helper failure can prevent the final loss summary from being delivered. The core reports failure
unless it receives activation, successful cleanup, and an exit record from a successful helper process.

Normal command exit, cancellation or supervisor death kills all remaining scope descendants before cgroup
removal. BPF attachments are persistent cgroup attachments, not links whose close would detach policy.
If the helper is killed, its direct child has a parent-death signal and surviving descendants retain BPF
restrictions. Owner recovery is required for a retained cgroup. Existing allowed proxy connections and proxy
lifetime/reuse are core/proxy responsibilities; this backend does not claim continuous TCP revocation.

## Validation and limits

`zig build test` includes actual unprivileged namespace, Landlock and seccomp tests. The test runner must
allow ordinary socket creation and unprivileged user namespaces. Tool sandboxes and some CI hosts may
disable these facilities. Tests never invoke sudo or install a helper. Temporary-project tests cover cwd,
project writes and executable files, hidden siblings and read-only state for multiple scopes. Protection
fixtures run 58 mutation attempts in each of a normal directory, `/tmp` and `/var/tmp`: file content and
metadata, symlink metadata, rename-over and rename-exchange, file and ancestor removal, state writes, new
hard links and outside-process `/proc` aliases. They also check neighboring writes and protected execution.
Separate tests reject existing hard links, intermediate symlinks, an actual alternate bind mount, and
inherited standard descriptors that would bypass protection. Generated BPF branch bounds and invalid
launch inputs also have unit checks.

`zig build linux-probe` installs an explicit backend harness for receiver tests:

```sh
mkdir -p out/linux-probe
zig-out/bin/blackice-linux-probe 18780 out/linux-probe/receipts.local.jsonl -- COMMAND ARGUMENTS
```

This harness treats the supplied ports as controlled receivers; it is not a domain policy proxy. Use fresh
receipts and controlled destinations for each run. The broader regression matrix includes immediate/forked
execution, both UDP modes and families, direct DNS, daemon IPC, inherited sockets, cgroup migration,
SCTP/ping sockets, descendant cleanup and failure recovery. Evidence entries must distinguish executed
cases from untested ones. Off-host denial evidence requires observed positive controls and no denied
traffic; the recorded run above does not include the crash tests.

After the reviewed helper is installed, the Python standard-library harness runs local receiver controls
and actual backend cases. It checks TCP, both UDP modes/families, SCTP, unconnected ping sockets, the ping
command, UDPLITE, MPTCP, helper re-entry, cgroup migration and double-forked descendants:

```sh
python3 src/linux/integration.py
python3 src/linux/integration.py --crash-tests
```

The optional crash cases send SIGKILL only to processes launched by that test, using pidfds. Killing the core
must terminate the scope; killing the helper must leave its surviving descendants filtered. The latter case
intentionally retains an empty cgroup for owner teardown afterward. Logs are stored under `out/`; the harness
does not install anything, run sudo or create an evidence entry. These local tests do not replace the off-host
receiver required for P0-02. A missing helper is reported as blocked, never passed.

`python3 src/linux/evidence_check.py --help` describes the P0-01/P0-02 observation harness. It requires an
explicit installed-helper hash before invoking blackice and captures CLI output through pipes. A Python
receiver on a second machine runs over SSH; its log returns over that same connection, with no shared remote
log filename. IPv4/IPv6 TCP, UDP sendto and connected UDP controls must arrive before and after each scoped
sender, including a double-forked descendant. The harness checks kernel receipts as well as receiver silence,
saves raw observations in a fresh private `/tmp/bi-ev-*` directory, and never creates an evidence entry.
The summary omits the machine hostname and SSH command. Raw local logs remain private; public evidence
uses reviewed excerpts without hostnames, SSH login commands or private artifact paths.
`--controls-only` checks connectivity without executing blackice. Legacy protocol-v1 runs must explicitly
use `--legacy-protected-paths` and retain the missing file-protection limit in their evidence.

This provides a network boundary and protection of the explicit trusted paths, not a general filesystem or
same-user sandbox. Filesystem triggers, other shared files, terminal output, and cooperation from an
unrelated outside process are not comprehensively isolated. The state root and its ancestors are protected
through their mounted paths; pre-existing hard links to individual state files elsewhere are not scanned.
Protected-file hard links and filesystem mount aliases are refused as described above. Allowed endpoints
may receive arbitrary permitted payloads.
Root resistance, arbitrary container/network namespaces, application identity and host-wide filtering are
not provided. Proxy port ownership, policy/grant authority and model-relay authentication require their own
evidence.

Kernel references: [BPF UAPI](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/bpf.h),
[ring buffer](https://docs.kernel.org/bpf/ringbuf.html),
[cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html),
[Landlock](https://docs.kernel.org/userspace-api/landlock.html), and
[seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html), and
[openat2 path resolution](https://man7.org/linux/man-pages/man2/openat2.2.html).
