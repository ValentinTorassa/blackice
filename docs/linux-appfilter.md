# Linux application filter — review candidate

This build implements the Linux apps ADR revision 3.1 on a separate branch. **It has not been loaded,
attached, installed, or tested against real application traffic.** Userspace unit tests and cross compilation
are preparation for security review, not evidence of kernel enforcement. The existing task-scope helper is
unchanged.

The initial target is Debian 13, `6.12.113+deb13-amd64`, x86-64 baseline. Startup checks the exact release and
SHA-256 of `/sys/kernel/btf/vmlinux`:
`5727b13fd2212290ae031719c9367251c0c8eda0a3f48181af71452ccf5f8943`.
A mismatch refuses arming; a refused start does not mean applications are filtered.

Build and userspace tests:

```sh
zig build linux-appfilter linux-appfilter-test
scripts/linux-build-appfilter.sh
```

The second command prints hashes for the stripped static `blackice-linux-appfilter` binary and its deterministic
installation bundle. Neither command installs on the host. Do not run setup, `app on`, or the service until
security clears the exact commit, bundle, scripts and kernel-load plan, and Valen approves the service footprint.

After the installation and first-load gate, the CLI flow is `blackice app on --policy APPS.json`,
`blackice app status`, and owner-authorized `blackice app off`. A sample policy is
[`examples/linux-apps.json`](../examples/linux-apps.json); close listed applications before arming.
These commands have not been run for this candidate.

## Identity and decisions

Three `tp_btf` programs tag an exec by its kernel `(device, inode)`, copy its tag at every fork, and clear it
only when the thread group dies. A 4,194,304-slot array covers every possible initial-namespace tgid; fork writes
zero too, preventing PID reuse from keeping an old tag. The first listed application remains the identity across
reexec and detached descendants. Only the authenticated owner's real UID acquires a new listed identity.

Five legacy cgroup programs attach at `/sys/fs/cgroup/user.slice`: connect4/6, UDP sendmsg4/6, and INET socket
creation. Listed TCP 80/443 goes to the application's HTTP/TLS loopback listeners. IPv4, native IPv6 and mapped
IPv6 are handled explicitly. Other TCP ports, non-stub UDP, QUIC, raw INET sockets, ICMP/ping, SCTP, UDPLite and
MPTCP are refused. UDP DNS to `127.0.0.53:53`, including its mapped IPv6 spelling, is allowed. TCP DNS is refused.
Unlisted processes retain their network access, except that loopback listener ports require the matching app tag.

Each app has HTTP and TLS ports in 760–773, with port 774 reserved. Both `127.0.0.1` and `::1` are bound; there
are no wildcard listeners. Arming reserves the entire 760–774 range and refuses any collision. The service checks
that `ip_unprivileged_port_start` is greater than 774 before binding. The connect hooks cover all 127/8, ::1 and
mapped 127/8 spellings for `listener_peer` checks. Processes in system services are outside that attach point.

The proxy checks exactly one TLS ClientHello SNI, or one HTTP Host header in an origin-form request. It resolves
and dials that name using the existing policy and resolved-address checks, not the original destination IP.
Duplicate SNI, malformed/fragmented ClientHello, missing names, CONNECT on a transparent listener, ambiguous
HTTP Host and IP literal routing are refused. ECH is decided by the outer name. TLS contents are not inspected.

Receipts use the existing JSONL writer, with `point: app_filter`, `app_id` and `executable`. Kernel refusals go
through a ring buffer; overflow increments a counter and is reported as `receipt_loss`. Files are service-owned,
mode 0640 under a service-owned 2750 directory whose group can read but cannot change them. Queued kernel
receipts retain the event's monotonic nanoseconds in `detail`; `ts` is the writer's drain time.

## Service and recovery

The root-installed executable has **no file capabilities**. A dedicated system user receives BPF, PERFMON,
NET_ADMIN and NET_BIND_SERVICE through its unit. A separate root bootstrap unit mounts only the fixed private
bpffs. It runs outside the daemon's private mount namespace, so pins survive daemon restarts. The daemon uses
NoNewPrivileges, non-dumpability, read-only system/home views and a private temporary directory.

Arming pins maps and its phase, legacy-attaches the socket programs, reserves listeners, pins exit/fork/exec
links in that order, and runs a kernel task iterator. Already-running listed files without tags make arming
fail. Only after this does it persist `armed`, drop load capabilities and acknowledge the caller. A restart rolls
back an incomplete phase; an armed restart reopens pins, verifies program tags, referenced map IDs/layouts and
cgroup attachments, refreshes file identities, binds listeners and drains queued receipts. Pinned links keep
classification running during a service crash. Pinned legacy program handles permit exact detach at authorized
off without replacing another program.

BPF and PERFMON are removed from effective, permitted, inheritable and ambient capability sets after arming or
reopening. The loader requires exactly one thread and verifies the drop before starting proxy workers: Linux
capabilities are per-thread. The bounding set still contains the unit's four caps: dropping bounding bits would require adding
SETPCAP, which this candidate does not do. NoNewPrivileges plus the cleared sets prevent reacquiring the load
caps through exec. NET_ADMIN and NET_BIND_SERVICE remain for detach and protected listeners. This distinction
is explicit for security review.

The control socket is systemd-owned. SO_PEERCRED plus SO_PEERPIDFD identify the configured non-root owner;
requests cannot supply a PID, UID, cgroup, program, map FD or BTF. Tagged callers are refused before polkit.
Off uses the peer pidfd over D-Bus/SCM_RIGHTS with an `auth_admin` action, without retained authorization or a
PID-number fallback. A dead peer or failed/ambiguous response refuses the operation.

This first candidate changes an active policy through an authorized `off`, then a fresh `on`; it refuses a
different policy while armed. It does not silently reassign IDs held by existing descendants. In-place policy
updates are a follow-up.

## Limits to review before installation

- Fresh arming currently requires those five attach points to be vacant. It refuses an unknown program ID:
  Linux 6.12 requires SYS_ADMIN to open arbitrary program IDs for name inspection, and the service intentionally
  lacks that capability. ALLOW_MULTI is used, but this candidate does not yet accept pre-existing systemd programs
  at the same points. The owner's root preflight determines whether this limit affects this host.
- Policy executable paths must be canonical, root-owned regular executable files with root-owned, non-writable
  ancestors. Symlinks and home-directory applications are refused. List the resolved installed binary.
- File identity is not code integrity or a publisher signature. Scripts are identified by their interpreter;
  listing it covers all scripts it runs. AppImages are unsupported.
- Inotify adds replacement file identities and retains old entries. A launch before a replacement is noticed,
  including while the service is down, is not tagged. A descendant already started before arming and now running
  another file is not discoverable by the task iterator. Processes an app started before arming are not covered.
- DNS through the stub is a full two-way data channel. Unix sockets, delegated work through D-Bus/systemd/portals,
  sockets connected before arming and sockets inherited or received from an unlisted process are not fully
  contained. Connected sockets, protocols without these connect/sendmsg hooks, and sockets created outside
  user.slice can bypass the checks on later use.
- Clipboard/session-socket access is not blocked by this app filter and has not been tested with real data.
- Root, other privileged software, system services and other users are outside the application's identity
  boundary. A system service can reach a proxy port and produce receipts attributed to that app.
- IO_uring identity attribution, kernel verifier acceptance, post-capability-drop map updates, crash recovery,
  polkit interaction, protected-port rebinding and application traffic all still need the approved installed run.
  Restart receipts report lost events; exact downtime is not measured and is labeled unknown.
- The retained executable-identity map has 4096 entries. Exhaustion refuses an update and stops the service;
  existing pinned identities remain restricted. A newly replaced file in that failure window is not covered.

## Security gate and sources

Security reviews the complete setup/teardown/bootstrap/unit/polkit diff and two reproducible builds. The owner
must approve the new service/system user and any missing `bpftool` package. Setup never installs packages or
changes sysctls, nftables or sudoers. Its root-owned staged bundle and binary must match the reviewed hashes
before any file is installed. Teardown stops socket activation, detaches only pinned handles, unpins/unmounts
and removes the service; receipts/policies are retained under a root-only directory. Reinstallation refuses
that archive until the owner moves it aside; setup never adopts or erases preserved evidence.

Before installation, record the existing cgroup programs, program list, nft ruleset, bpffs, groups, protected
hardlinks/BPF/Yama/port sysctls and listeners in 760–774. Do not conflate this record with a passing load.

Implementation references: Linux 6.12 [`do_exit`](https://github.com/torvalds/linux/blob/v6.12/kernel/exit.c)
decrements `signal->live` before the exit tracepoint; [`bpf_prog_calc_tag`](https://github.com/torvalds/linux/blob/v6.12/kernel/bpf/core.c)
normalizes map-FD immediates before hashing; [`BPF syscalls`](https://github.com/torvalds/linux/blob/v6.12/kernel/bpf/syscall.c)
define link and ID-access behavior. Polkit 126's
[subject decoding](https://github.com/polkit-org/polkit/blob/126/src/polkit/polkitsubject.c) accepts the passed pidfd
and UID without the legacy PID/start-time fallback used by older clients.
