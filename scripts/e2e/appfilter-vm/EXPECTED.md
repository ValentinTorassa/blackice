# Linux app filter: kernel tests in a disposable VM

These tests exercise the kernel side of the Linux application filter (`src/linux/apps/`) on the pinned
Debian kernel, inside a throwaway VM. They never run on a real machine: `run.sh` refuses the demo VM, and
every privileged step happens inside the VM over its ssh wrapper.

```
scripts/e2e/appfilter-vm/run.sh --vm <vm dir with vssh> --commit <sha> \
    --binary-sha <service sha256> --bundle-sha <bundle sha256> [--cli-sha <release CLI sha256>] \
    --label dry-run|evidence --results <dir> [--agent yes|no] [--extra] [--skip phase,...] [--secret-dir <dir>] \
    [--only interactive,reboot,teardown]
```

`--only` re-runs blocks against the kit already installed and verified in the VM, after a harness fix. It
refreshes `aftest.py` only, never a product file, and its results directory ends in `-rerun`. Say so whenever
it is used for evidence.

`--agent yes` means the commit's CLI starts `pkttyagent` for `app off` on a terminal, so the interactive cases
expect a password prompt. Use `--agent no` for a commit without it: every interactive case then expects a
refusal with no prompt.

## What the driver does

1. Checks `uname -r` in the VM is `6.12.113+deb13-amd64` before anything else, and that the VM is not the demo
   VM.
2. Installs the test packages in the VM (git, cron, at, systemd-resolved, btrfs-progs, curl, wget, bpftool,
   nftables, polkitd, libcap2-bin, dbus-user-session), and copies Zig 0.17.0 in if it is missing.
3. Copies `git archive <commit>` into the VM and records provenance: the source tree hash computed in the VM
   against the commit's tree, uname, the BTF sha256, the Debian version and the Zig version.
4. Builds as the VM user, with `scripts/linux-build-appfilter.sh`, and `zig build release` for the CLI
   (`zig-out/release/blackice-x86_64-linux`). It stops if the bundle, service binary or CLI hash differs from
   the reviewed hashes passed in.
5. Moves aside what an earlier run left in the VM. It refuses if an app filter is still installed. It archives
   `/var/lib/blackice-appfilter`, which setup refuses to adopt, under `/var/tmp/aftest-archive/`, and moves
   earlier results aside.
6. Installs the kit under `/opt/aftest`: the CLI, `uringprobe`, the reviewed setup and teardown scripts with the
   bundle, `aftest.py`, and the policies in `/opt/aftest/policies`, never in `/etc/blackice-appfilter`.
7. Runs the phases of `vm/aftest.py` one at a time as root, drives the interactive cases from the host, and
   fetches `/var/tmp/aftest/results` into `<results>/<label>-<short sha>-<UTC time>/`.

## What each case writes

`cases/<case>/log.txt` holds every command, its output and every check. Next to it are `tree-before.txt/.json`
and `tree-after.txt/.json` (the `bpftool cgroup tree` plus the JSON view of our programs, links and pins), plus
journal extracts where relevant. `results.jsonl` holds one line per check, and `summary.txt` the totals. A
dry run says `DRY RUN (debugging only, not evidence)` in every log header.

Verdicts:
- **PASS / FAIL**: the expected value is stated in the check itself.
- **OBSERVE**: a recorded behaviour that security classifies; it is not a pass.
- **SKIP**: the kernel lacks the feature (for example MPTCP disabled); preflight says why.

A FAIL is a finding unless the log shows a harness problem. Expectations are never changed to make a product
result pass.

## Users and policies

- Owner: the VM user (`test`). Second user: `other`. A10 needs the owner's user bus, so P1 installs
  dbus-user-session and starts `dbus.socket` for the owner.
- Six-app policy (`tests.json`), used for the listener-guard matrix. App id = position, and ports
  `760 + 2(id-1)` (TLS) and +1 (HTTP).
  1. `/usr/bin/setsid` (example.com)
  2. `/usr/bin/env` (example.org)
  3. `/usr/bin/nice` (example.com)
  4. `/usr/bin/curl` (example.com)
  5. `/usr/bin/wget` (example.org)
  6. `/opt/aftest/launch/aft-launch`, a root-owned copy of setsid (example.com)
- Apps 1, 2, 3 and 6 serve as launchers: a probe started through them carries that app's tag.
- Curl-only policy (`host-curl.json`): `/usr/bin/curl` with `example.com`, like the owner's first host policy.

## Cases

### P0–P4: preparation

- **P0 preflight.** Kernel and BTF hash equal the pins, the hostname is not demo-vm, and the root filesystem is
  ext4/xfs. The sysctls that matter are recorded.
- **P1 provision.**
  - Mirrors valendebian's sysctls (ptrace_scope 1, unprivileged_bpf_disabled 2, ip_unprivileged_port_start
    1024) and records any change.
  - Creates the `aftest` netns: veth `aft-h`/`aft-n`, `10.99.0.1/.2`, `fd99::1/::2`, plus `fd99::12/13/14`.
  - Starts a TCP server on 9000 and a packet sniffer, both inside the netns.
  - Checks `/etc/resolv.conf` is the resolved stub.
- **P2 baseline.** Records the cgroup tree; the foreign attachments in it are what later cleanups must equal.
  No `bi_af_` program, nothing listening on 760–774.
- **P3 setup.** The reviewed setup script with the reviewed hashes exits 0. The service binary has no file
  capabilities, the socket unit is active, and no BPF is loaded at setup.
- **P4 arm.** `app on` with the six-app policy prints `OK armed`.
  - Precondition (V1): `ss -tan state time-wait '( sport >= :760 and sport <= :774 )'` is saved as
    `P4-time-wait-precondition.txt`, and the first arm waits (up to 90 s) until it is empty. Any TIME_WAIT seen
    later then comes from this build's own traffic.
  - All seven hooks are attached: `bi_af_conn4/conn6/send4/send6/create` at `user.slice`, and
    `bi_af_peer4/peer6` at the cgroup root.
  - `ProtectControlGroups=yes` is in effect, and an `app_filter_on` receipt is written.
  - Each launcher tags its child: it connects to its own listener and gets EPERM to the netns. An untagged
    process gets EPERM to the listener and connects to the netns.

### A3-R1: the start limit while off (`startlimit`, right after setup, before the first arm)

While off, the service is socket-activated once per control request and exits after answering, so every
request is a start that counts against `StartLimitBurst`.
- A3R1a: 30 `blackice app status` calls by the owner, with no reset-failed first (the state before and the
  number of service starts this boot are recorded). All 30 must answer `OK ...`. On a failure the first failing
  call, both units' `Result` and systemd's lines are recorded, then the owner's `app on`, and then root's
  `reset-failed` plus starting the socket must bring status back to `OK off`. After a socket trigger-limit hit
  (8ba8cca: systemd's default 20 activations per 2 s), root first waits out `TriggerLimitIntervalSec` plus 1 s:
  a restart inside the window is refused again on the next connection. The wait is recorded.
- A3R1b: root holds `127.0.0.1:765` and the owner runs `app on`: refused with `ListenerPortOccupied`. In the
  journal from that moment on: at most one automatic restart, no start-limit line, the service not failed and
  the socket listening, and status answers `OK off`.
- A3R1c: 30 `app status` calls by the owner, 2 s apart (30 in 60 s, security's criterion). All answer `OK ...`,
  and the journal has no start-limit or trigger-limit line.

### A: the root-cgroup listener guard (H1)

Each caller runs the H1 probe.
- **Destinations.** Every spelling of a local address on every port 760–774: 127.0.0.1, 127.0.0.2,
  127.255.255.254, 0.0.0.0, 0.1.2.3, ::1, ::, ::ffff:127.0.0.1, ::ffff:127.0.0.2, ::ffff:0.0.0.0,
  ::ffff:0.1.2.3, plus ::127.0.0.1 and the VM's own addresses as non-local.
- **Other paths.** TCP Fast Open (`MSG_FASTOPEN`) and MPTCP (protocol 262), on a subset.

Expected, per attempt (`h1_expect`):
- untagged caller, local destination: `EPERM`;
- untagged caller, non-local destination: anything but connected;
- tagged caller, its own port, exact address: connected;
- tagged caller, its own port, unspecified address: connected or `EPERM` (either way, only its own listener);
- tagged caller, its own port, any other local spelling: not connected;
- tagged caller, another app's port or 774: `EPERM` when local, not connected otherwise;
- tagged caller, MPTCP: `socket:EPERM` (refused at creation).

MPTCP outcomes `EPROTONOSUPPORT`/`ENOPROTOOPT` are skipped and counted.

Callers, each with a placement check on the cgroup it runs in:
- A01: the owner's cron job (system.slice);
- A02: another user's cron job (system.slice);
- A03: the owner's at job (system.slice);
- A04: a system service running as the owner;
- A05: a system service running as root;
- A06: another user in user.slice;
- A07: another user running a listed launcher, which must stay untagged;
- A08: the owner, untagged;
- A09: root in user.slice;
- A10: the owner's `systemd --user` service;
- A11–A14: tagged apps 1, 2, 3 and 6.

A20: tagged MPTCP sockets get EPERM for inet and inet6 at creation. The `listener_peer` refusal receipts are
counted (OBSERVE).

### B: inbound from another netns (M2)

- B01–B03: a tagged listener on `0.0.0.0`, `::` or an autobound port is bound to `lo`. A connect from the netns
  fails, and nothing is accepted.
- B04–B06: the same listeners untagged accept the netns connection (controls).
- B07: a tagged listener's accepted sockets are bound to `lo`.

### C: binding to a device (M2)

- C01: a tagged TCP or UDP socket starts bound to `lo`. `SO_BINDTODEVICE` (to the veth or to "") and
  `SO_BINDTOIFINDEX` (to the veth or to 0) all give `EPERM`, and the socket is still on `lo`.
- C02: untagged sockets start unbound and may bind (control).
- C03: `IP_PKTINFO` / `IPV6_PKTINFO` naming the veth, from a tagged UDP socket, puts no packet with its token on
  the veth. An untagged control token is seen, which proves the sniffer works.

### D: IPv6 segment routing header (M3)

- D01: an untagged connect with a type-4 routing header reaches its first hop `fd99::2` (control).
- D02–D04: tagged connects with an SRH to ports 443, 80 and 9 fail, and nothing reaches the first hops
  `fd99::12/13/14`.
- D05: IPv4 LSRR: the setsockopt result is recorded (OBSERVE; expected EPERM unprivileged on 6.12).

### E: stub DNS and redirects (M2)

- E01: tagged UDP DNS to `127.0.0.53` and `::ffff:127.0.0.53` is answered.
- E02: tagged TCP to 1.1.1.1, 2606:4700:4700::1111 and ::ffff:1.1.1.1 on 443/80 is redirected to the app's own
  listeners. `getpeername` shows `127.0.0.1:760/761`, `::1:760/761` and `::ffff:127.0.0.1:760/761`.
- E03, real requests through the proxy: curl to https/http://example.com/ gives 200, and curl to
  https://example.org/ fails. wget to https://example.org/ succeeds, and wget to https://example.com/ fails.
  Curl over IPv6 and the receipts are recorded (OBSERVE).

### S: the service and its proxy child (security's 5517189 list, items 1, 2, 4, 5, 7, 8)

- **S01 (M5), the proxy child.** The service has exactly one child.
  - Every thread of it has CapEff/CapPrm/CapInh/CapAmb 0, NoNewPrivs 1 and Seccomp 2.
  - Its fds are only the 760–773 listeners (matched by socket inode against `/proc/net/tcp{,6}`), its proxy
    receipt files under `/var/lib/blackice-appfilter`, and fds 1/2.
  - It holds every listener. `ls -l /proc/<child>/fd` is kept.
- **S02 (M5), the loader after arming.** Every thread has CapEff 0, CapPrm exactly `cap_net_admin` (0x1000) and
  CapAmb 0. Its fds are inventoried (OBSERVE).
- **S03 (M7), header timeout.** A tagged client connects to its own listener and sends nothing. It is closed by
  the server after 4–7 s, and one more `header_timeout` receipt is written.
- **S04 (M7), connection limit.** 16 tagged connections spread over the app's four listeners stay open. The 17th
  is closed without a reply within 2 s, and a `connection_limit` receipt is written.
- **S05 (M8), replacement.** The listed launcher file is replaced (rename over it; twice in a row from iteration
  20), and a launch 0.5 s later is tagged: 50 of 50. Ten launches with no pause are recorded (OBSERVE: they race
  the refresh).
- **S06 (M9), receipt file limit.** Tagged TCP connects to the netns are refused, 40k at a time, until
  `write_dropped` rises in `app status`. Then the largest receipt file is within 64 KiB below
  `receipt_file_limit` (8 MiB), never above it. The `receipt_loss` lines and `ring_dropped` are recorded.

### F and G: restart, kill-then-fork, off, kill at each arming phase, host-like sequence, teardown

The final commit limits the unit to 5 starts in 600 s (`StartLimitBurst`/`StartLimitIntervalSec`, recorded in
P3). The harness kills the service on purpose many times, so it runs `systemctl reset-failed` before each
deliberate kill. That clears the start counter only; it never restarts anything by itself.

Every case (except A3R1a) starts with `systemctl reset-failed` on the service and the socket, and starts the
socket if it is not listening. The state before goes to the case log, and to `<case>.harness-reset` (OBSERVE)
when a unit was failed. One start-limit hit (A3-R1 on 63a38cc) then cannot cascade into later cases.

While off, the service exits after each valid request, so the cases that need its pid before `app on` (G11–G15)
first open the control socket as root: the request is refused (`NotOwner`) and the service keeps serving after a
refused request, so its MainPID holds until the next valid one. Recorded as `<case>.wake`; it leaves one
`app_filter_control` deny receipt.

Journal excerpts keep only lines at or after the exact start of the step (journalctl's `--since` takes whole
seconds).

A failure that leaves the service down would also fail every later case. To stop that, the cases from F02 on
start with a harness recovery when the control socket does not answer:
- wait until no TIME_WAIT socket holds a listener port (up to 75 s);
- `systemctl reset-failed` both units;
- start the socket.

Each recovery is recorded as `<case>.harness-recovery` (OBSERVE). The failure itself stays recorded in the
case that caused it.

- **F01 crash.** SIGKILL the service.
  - While it is down, the seven attachment ids are unchanged: the pins hold.
  - systemd restarts it within RestartSec=1 (`NRestarts`+1), still `OK armed`.
  - An `app_filter_restart` receipt is written, and curl gets 200 afterwards.
  - A tagged connect during the gap is recorded (OBSERVE; it races the restart).
- **F02 stop/start.** `systemctl stop` keeps the pins. The next `app status` socket-activates the service, and
  it reports armed.
- **F02b (M5), kill the proxy child.**
  - SIGKILL the child, and the loader exits within 5 s.
  - The seven attachment ids are unchanged, and a tagged curl fails while the unit is not active.
  - systemd restarts the service (`NRestarts`+1). It reports armed and writes one more `app_filter_restart`
    receipt, and curl gets 200 again.
  - The TIME_WAIT sockets on 760–774 at the kill are recorded (F01 too). On 6c849ec a restart right after
    proxied traffic failed with `ListenerPortOccupied` until the start limit was hit.
- **F02c, the backoff unit (`RestartSteps` > 0, 8ba8cca on).** `RestartSteps`+1 kills of the service. Each
  restart is timed from the kill to an active unit with a new MainPID, reading systemd only (a control request
  would start the service at once and skip the delay). The delays must rise (non-decreasing within 0.5 s) to at
  least 30 s, no kill may end in `failed`, and the journal has no start-limit line. In every gap the seven ids
  are unchanged and a tagged app gets EPERM to the netns. It ends armed with curl 200.
- **F02d (backoff unit), a live collision during an armed crash recovery.** Armed; the loader is killed and
  root binds `127.0.0.1:765` (with SO_REUSEADDR, retrying until the service's listeners are gone) before the
  restart. For 25 s: restarts are refused (exit 125) at least twice, with rising gaps between starts, the seven
  ids stay and a tagged app gets EPERM to the netns. After root releases the port the unit must be active and
  steady within 60 s (systemd only, no control request), then armed, with a restart receipt and curl 200.
- **F02c (A3), start limit (units without `RestartSteps`).**
  - Kill the service repeatedly with no traffic in between. After exactly `StartLimitBurst` restarts, the next
    start is refused: the unit is `failed`, and `start-limit-hit` shows on the unit (`Result=start-limit-hit`)
    or, with socket activation, on the socket (`Result=service-start-limit-hit`). The service's own `Result` is
    the reason of its last exit (`signal`). Both units' states are recorded.
  - The seven attachment ids are unchanged, a tagged curl fails, and an untagged connect to `127.0.0.1:760`
    still gets EPERM.
  - `systemctl reset-failed` on both units, starting the socket and an `app status` bring it back armed, and
    curl gets 200 again.
- **V1 (63a38cc on): listeners through TIME_WAIT.**
  - V1a: Codex's VM socket test (`src/linux_appfilter_listener_test.zig`), compiled on the host with
    `zig test ... --test-filter 'VM listener' --test-no-exec -target x86_64-linux -mcpu baseline -O ReleaseSafe
    -fstrip`, never run there, and checked against the reviewed sha256 before it is copied in (run.sh
    `--listener-test`). In the VM it runs as the owner and must pass 2 of 2 (IPv4 and IPv6: `SO_REUSEADDR` 1,
    `SO_REUSEPORT` 0, server-side TIME_WAIT observed, immediate rebind, a live second listener refused). Its
    sha256 and `sys_vendor` (QEMU) are recorded.
  - V1b1/V1b2/V1b3: after proxied TCP traffic, kill the proxy
    child, kill the loader, or `systemctl restart`. The traffic is three tagged connections to app 1's TLS
    listener that send nothing, which the proxy closes at its 5 s header deadline (so TIME_WAIT is on the
    listener port; curl closes first and leaves it on its own port), then six allowed requests and one refused
    name. TIME_WAIT on 760–774 must be present before the restart and
    when it re-arms (both saved). It comes back active (NRestarts+1, or a new MainPID for `systemctl restart`),
    armed, with one more `app_filter_restart` receipt, no `ListenerPortOccupied` / `listener_unavailable` /
    start-limit line in the journal, and curl filtered as before.
  - V1e: an authorized off right after traffic, then `app on` at once with TIME_WAIT present: `OK armed`, no
    listener errors.
  - V1c (IPv4 and IPv6): root holds a live listener on `127.0.0.1:765` or `[::1]:765`. `app on` is refused,
    with an `app_filter_on_failed` receipt with reason `listener_unavailable`, status `OK off`, a clean tree,
    and the cgroup tree equal to the picture before `app on`.
  - V1d: armed again, `ss -ltnp` shows 30 listeners, exactly one per port and family (no `SO_REUSEPORT`
    duplicates), all owned by processes in the service's cgroup.
- **G01 kill-then-fork.** A tagged forker process stays alive while the service is SIGKILLed and stopped (the
  automatic restart is cancelled).
  - A fork while the service is down is still tagged: EPERM to the netns, ECONNREFUSED on its own port.
  - A new launch through a listed launcher while down is tagged in the same way.
  - An untagged process is unaffected.
  - After socket activation brings the service back, a fork connects to its own listener again.
- **F03 off authorization** (security case A, steps 1–2).
  - With no aftest rule, off is refused.
  - From a tagged caller, off is refused.
  - From a tagged caller with the rule present, off is still refused.
  - The filter stays armed throughout.
- **F04 off** (case A, steps 3–4).
  - The VM-only rule is written, `app off` prints `OK off`, and the rule is removed at once.
  - All seven hooks are detached. No `bi_af_` program, pin or listener is left, and the foreign attachments
    equal the baseline. The one tolerated difference, recorded as OBSERVE: systemd's own `sd_devices` /
    `sd_fw_*` on a `system.slice/<unit>.service` cgroup, which systemd adds when a service starts after the
    baseline (polkit.service is D-Bus activated by the first authorization) and removes when it stops. Every
    other difference fails, with the added and removed rows.
  - An `app_filter_off` receipt is written.
- **F05.** Arming again with the six-app policy works.
- **G11–G15 kill at each arming phase.**
  - While `app on` runs, the service is single-stepped with SIGSTOP/SIGCONT. The pinned `state` map's phase is
    read with raw `bpf()`, and the service is SIGKILLed when the phase is maps (1), cgroup (2), listeners (3),
    tracking (4) or armed (5).
  - Single-stepping only reaches `maps`: each SIGSTOP/SIGCONT leaves a signal pending, the kernel verifier then
    returns EAGAIN from BPF_PROG_LOAD, and `app on` fails with KernelFailure and rolls back (8ba8cca run). So each
    case first tries three free-running attempts: `app on` runs unstopped, a tight loop reads the pinned phase,
    and the service is SIGKILLed when it equals the target. The phase at death is read back from the pin before
    the restart, and the attempt counts only if it is the target. Two single-stepping attempts follow as a
    fallback. If every attempt misses, "reached" fails: that is a harness limit, not a product result.
  - After the restart, for phases 1–4: `OK off`, no attachments, programs, pins or listeners, foreign
    attachments equal to the baseline, one more `app_filter_on_failed` receipt with reason
    `interrupted_arming`, and arming works again.
  - For phase 5: `OK armed`, seven hooks, and an `app_filter_restart` receipt.
- **F06–F08 host-like sequence.** With the curl-only policy:
  - F06: arm; curl to example.com gives 200 and to example.org fails.
  - F07: off through polkit, using the one-request rule. It must print `OK off` and leave a clean tree equal to
    the baseline, with an `app_filter_off` receipt (reason `owner_authorized`). Both curl requests then succeed
    without the filter, and the polkit journal is kept.
  - F08: arm again.
- **B00–B9: the real polkit path** (security case B). This runs after the last use of the VM-only rule, so that
  rule does not exist during these cases.
  - B00 records the setup: the owner is in group `sudo` (Debian's admin rule is `unix-group:sudo`),
    `/usr/bin/pkttyagent` is present, the admin rule's text, and the owner's password state. The password is
    random per run, set with `chpasswd` from stdin, kept in a 0600 file outside the results, scrubbed from
    transcripts, and locked again afterwards.
  - Each case opens a fresh interactive login shell with `ssh -t`, as the owner, with no desktop, under a pty on
    the host (`interactive_off.py`). It sets a marker prompt, types `blackice app off` and answers the agent the
    way a person would. When the prompt comes back it types `echo AFTEST-RC=$?` on its own line: bash drops the
    rest of a typed `cmd; echo $?` list when the command dies of Ctrl-C's SIGINT. Afterwards the same shell records `stty` and types a random token, which shows whether
    terminal echo came back. The VM side records the state before, the transcript, and the state after, with
    the before/after trees.
  - Cases:
    - B1 correct password: a prompt, `OK off`, status off, a clean tree, an `app_filter_off` receipt, and both
      curl requests unfiltered. The time from the prompt to the answer is recorded against the 15 s budget.
    - B2 wrong password: refused, still armed, no new off receipt, and curl still filtered.
    - B3 Ctrl-C at the prompt: refused and still armed.
    - B4 no answer: refused between 10 and 40 s (one 15 s polkit budget for the whole exchange), still armed.
      While it waits, an `app status` from a second session is timed (OBSERVE: shows whether the service
      blocks).
    - B5 `app off </dev/null` without `-t`: no agent starts, it is refused with no prompt, and it stays armed.
    - B7: root moves `/usr/bin/pkttyagent` aside, and the owner types `app off` under
      `strace -f -e trace=connect,execve`. It fails with no prompt and stays armed, and the trace has no
      `connect()` to `/run/blackice-appfilter/control.sock`: it failed before contacting the service. The
      file is moved back and must have the same sha256, owner and mode.
    - B8: root removes the owner from group `sudo` (`/usr/bin/gpasswd`), as on valendebian, where the group is
      empty. polkitd then falls back to uid 0 and asks for root's password. Answered with the owner's password,
      `app off` is refused and the filter stays armed.
    - B8a: root gets a random password (`chpasswd` from stdin, kept like the owner's). Answered with root's
      password, the filter turns off. This is what the admin fallback allows on a host whose admin group is
      empty.
    - B8b: re-armed, a wrong root password is refused and it stays armed. The owner then goes back into `sudo`.
    - B9: security's reviewed admin rule, with valen→test (sha256 0b943244…), is installed root:root 0644 as
      `/etc/polkit-1/rules.d/49-blackice-appfilter-admin.rules`, and the owner is still outside `sudo`.
      - B9a: the owner's own password turns the filter off.
      - B9b: re-armed, a wrong password is refused.
      - B9c: `pkexec true` with the owner's password is still refused, because it is a different action and
        the admin group is empty. The rule is then removed (`ls -la rules.d` is recorded before and after),
        and the owner goes back into `sudo`.
  - Every case except B5:
    - terminal echo is on afterwards (`stty` shows `echo`, and the typed token appears);
    - no `pkttyagent` of the owner is left (`pgrep -a -u test pkttyagent`, security's B6);
    - the service kept the same MainPID and NRestarts. In a case that turns the filter off, the service stops
      (MainPID 0): the pair is recorded (OBSERVE) and only NRestarts must be unchanged.
  - With `--agent no` (a commit whose CLI starts no agent), every case expects "no prompt, refused, still
    armed".
- **R01 (M6), after a VM reboot.** run.sh reboots the VM and checks the kernel again.
  - Status is `disarmed_by_reboot`, and no hook is attached: nothing re-arms by itself.
  - `app on` with a policy other than the one armed before the reboot is refused, and status still says
    `disarmed_by_reboot`.
  - An authorized off gives `OK off`, and then the other policy arms. The teardown runs with it armed.
- **F09 teardown while armed.**
  - The reviewed root teardown exits 0 with all seven hooks attached.
  - Afterwards: no `bi_af_` attachment, program, pin or listener, and foreign attachments equal the baseline.
    The unit files, libexec files, polkit action and `/etc/blackice-appfilter` are gone. No `blackice*` unit
    file is left, and the account is removed.
  - `/var/lib/blackice-appfilter` is kept, root:root, with no group or other access. The exact mode and the
    file owners are recorded.
  - An untagged connect to `127.0.0.1:760` gives ECONNREFUSED: no hook and no listener are left.

### The VM-only polkit rule

`/etc/polkit-1/rules.d/49-aftest-vm-only.rules` returns YES for the owner on `org.blackice.appfilter.change`.
It stands in for the owner typing the admin password, so the automated cases can turn the filter off. It also
proves L10: without the action's owner annotation, polkitd refuses the service's query about another user's
process, whatever the rules say.

The rule exists only for a single request: `authorized_off()` writes it, sends one `app off`, and removes it.
`polkit.service` is D-Bus activated. In c592f6e's run it was inactive and the service's CheckAuthorization did
not start it, so `app off` failed with `PolkitUnavailable`. `authorized_off()` records polkit's state before the
request. On `PolkitUnavailable` it records the state, starts polkit, retries once, and records both answers
(`<case>.polkit-unavailable`, OBSERVE).
Each case log keeps the rule's sha256 while it was present and `ls -la /etc/polkit-1/rules.d/` from before
and after. It never leaves the VM.

## Extras (`--extra`; outside the fixed list)

- **X01 (M4).** While off, policies naming files on tmpfs, overlayfs or a btrfs subvolume are refused, and the
  refusal names the file.
- **X10 (test 4), io_uring.**
  - `IORING_OP_SOCKET`+`CONNECT` from a tagged process gets PERM, inline and through io-wq.
  - 200 exiting rings send nothing.
  - An SQPOLL ring owned by an untagged process, used by a tagged one: the tagged socket stays on `lo` and
    another app's listener gives PERM. Socket creation inside the ring is recorded (OBSERVE: delegation).
- **X22 (M9).** 200k refused UDP sends: same MainPID and NRestarts, and the loss accounting is recorded.
