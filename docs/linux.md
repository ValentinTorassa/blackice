# Linux task scopes

This backend is an experimental managed-command implementation. It is not an app/host firewall. The helper,
launch handshake, BPF programs and receipt transport are implemented; privileged kernel enforcement still
needs an installed-helper run and receiver-side evidence. A passing build or namespace test is not P0-02.

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

These are implementation semantics, pending the privileged traffic matrix. IPv6 and UDP have no allow path.
Names and allowed remote destinations belong to the external proxy; the kernel does not resolve names.
Direct DNS cannot use UDP or arbitrary TCP. Resolver and service-manager IPC is also restricted.
Neither nftables rules nor unrelated host networking configuration is modified.

The setup grants `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_NET_ADMIN` and `CAP_BPF` only to a small, static,
stripped helper. The workload and `blackice` receive no file capabilities. The helper creates its own child;
there is no arbitrary-PID attach API. It pins process lifetimes with pidfds, verifies enrollment and all four
attachments, and holds the child behind a two-stage pipe handshake until containment is armed.

Before exec, the child closes all unexpected descriptors, drops host capabilities, creates private user/mount
namespaces, and masks `/run`, `/var/run`, `/tmp` and `/var/tmp`. The caller's numeric uid/gid and working
directory are preserved, reopening cwd through the new mounts. A working directory or executable inside a
masked path may therefore be unavailable. The scope state directory is recursively mounted read-only.
Landlock ABI 6 scopes abstract Unix sockets and signals. Finally, all capabilities are dropped and an
inherited seccomp filter and `no_new_privs` prevent reacquiring privilege. Socket-backed standard input,
output or error is rejected rather than inheriting an outside socket's cgroup attribution.

The core contract now includes `state_dir`. During integration with the earlier contract, the backend derives
the canonical state directory from the open receipt descriptor. It never substitutes an unprotected state
directory when this lookup fails.

## Build and install

Required: Zig 0.17.0, Linux with unified cgroup v2, cgroup BPF socket-address hooks and ring buffers, user/mount
namespaces, pidfds, `cgroup.kill`, `mount_setattr`, seccomp and Landlock ABI 6. Linux 6.12 is the initial target;
version alone does not prove the required kernel configuration. The helper refuses missing capabilities.
Source supports x86_64 and aarch64; only x86_64 has been exercised locally so far.

Build as the normal user:

```sh
zig build
zig build test
zig build linux-probe
./scripts/linux-build-helper.sh
```

The helper always uses ReleaseSafe with stripped debug information. Its panic path does not symbolize or
read source files, and Zig's segmentation-fault handler is disabled. The separate build script prints the
binary's SHA-256. Before installation, have the privileged helper and scripts reviewed, and compare that hash
with an independent build of the reviewed commit.

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

Recovery is an explicit owner operation:

```sh
sudo ./scripts/linux-teardown.sh
```

It disables new helper executions, terminates only blackice scope cgroups and removes only blackice's
helper/configuration. It is safe to repeat. A populated or stuck cgroup retains its attached policy;
teardown refuses to remove that boundary and leaves new launches disabled until owner recovery. Never
detach programs from a live scope as a shortcut.

## Receipts and lifetime

Kernel admission refusals enter a per-scope 64 KiB ring buffer. They carry the destination, port, protocol,
hook and kernel-observed process ID. The helper forwards fixed-size, versioned records on a private pipe;
only the blackice process writes JSON receipts. `kernel_drop` with `point: kernel` means the socket operation
was refused before transmission; it is not a claim that a packet reached an nftables hook. Seccomp refusals
at socket creation are not individual destination receipts, because no destination exists at that point.

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
disable these facilities. Tests never invoke sudo or install a helper. Generated BPF branch bounds and
invalid launch inputs also have unit checks.

`zig build linux-probe` installs an explicit backend harness for receiver tests:

```sh
mkdir -p out/linux-probe
zig-out/bin/blackice-linux-probe 18780 out/linux-probe/receipts.local.jsonl -- COMMAND ARGUMENTS
```

This harness treats the supplied ports as controlled receivers; it is not a domain policy proxy. Use fresh
receipts and controlled destinations for each run. Before recording P0-02, test immediate/forked execution,
both UDP modes and families, direct DNS, daemon IPC, inherited sockets, cgroup migration, SCTP/ping sockets,
descendant cleanup and failure recovery. An off-host receiver must observe positive controls and no denied
traffic. No P0 evidence file should be created until that real run exists.

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

This is a network boundary, not a general filesystem or same-user sandbox. Filesystem triggers, shared
files, terminal output, preexisting filesystem aliases, and cooperation from an unrelated outside process
are not comprehensively isolated. Scope state is read-only through its mounted path, not a general promise
about all aliases accessible to the same uid. Allowed endpoints may receive arbitrary permitted payloads.
Root resistance, arbitrary container/network namespaces, application identity and host-wide filtering are
not provided. Proxy port ownership, policy/grant authority and model-relay authentication require their own
evidence.

Kernel references: [BPF UAPI](https://github.com/torvalds/linux/blob/v6.12/include/uapi/linux/bpf.h),
[ring buffer](https://docs.kernel.org/bpf/ringbuf.html),
[cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html),
[Landlock](https://docs.kernel.org/userspace-api/landlock.html), and
[seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html).
