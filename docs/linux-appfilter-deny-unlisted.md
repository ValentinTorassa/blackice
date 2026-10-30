# Deny unlisted applications: disabled implementation draft

This branch contains a policy parser, recovery-state functions, a separate BPF instruction emitter and an
unconnected pin/attachment adapter.
**It cannot arm deny-unlisted mode.** The CLI and service refuse `"unlisted": "deny"` with
`ExperimentalUnlistedRuntimeNotReady` before new policy persistence or attachment. This is not a released feature,
a kernel-verifier result or permission to install it. Experiments belong only in the designated VM4.

The policy key is `unlisted`, with `allow` as its default. There is no agent exception or configurable exemption
list. Unknown fields and duplicate keys are refused. The existing app filter is described in
[Linux app filtering](linux-appfilter.md).

## Implemented and tested without privileges

- Independent gate ABI with an owner real UID, an arming epoch and a boot-time deadline. Preparation is inactive.
  Activation requires all five hook bits and an independently registered root timer; the VM window is five minutes.
- Confirmation decisions require fresh administrator authorization, the same owner and arming epoch, a live peer,
  no app tag, and an unexpired window. Confirmation commits until off/reboot; repeated confirmation adds no time.
  These are pure decisions, **not a wired polkit command**. The privileged adapter must collect the observations.
- Timer decisions ignore a stale epoch or a confirmed state. Deadline expiry disables B even with no userspace
  process running. There is no root timer service or wired emergency-off command in this draft yet.
- Five independent emitted programs: IPv4/IPv6 connect, IPv4/IPv6 UDP sendmsg, and inet socket creation.
  The existing listener guards and tracing programs are unchanged. The new emitter is not reachable from the loader.
  Unit tests execute the emitted instructions in a userspace interpreter; they do not load them into the kernel.
- An adapter prepares only an inactive gate, pins and verifies five separate programs and an alias of the base
  tag map, then requires the exact base program IDs before attachment. Partial failure leaves pins for recovery.
  Detachment targets only verified B descriptors and checks that all other IDs remain. Duplicate IDs, swapped
  pins and a B ID still present at any of the five hooks prevent cleanup. Gate pins are removed last.
  Pure tests cover the ID checks; taking references to the adapter's methods makes the compiler check their
  bodies without calling them. **Its privileged operations have not run.** Existing loader primitives are now
  public for reuse; their implementations and the base emitted programs are unchanged.
- A read-only VM4 identity preflight, with explicit guest machine/boot IDs, SSH key pin and KVM check. No sudo,
  polkit, install, BPF, service control or enforcement test is executed by that script.

## Intended boundary

An untagged process with the owner's **real UID** is refused at new outgoing socket operations, except UDP to
`127.0.0.53:53` and its IPv4-mapped IPv6 spelling. TCP DNS, `127.0.0.54`, native `::1`, other loopback endpoints,
DoH and other resolvers have no exception. Socket creation admits TCP streams and UDP datagrams for the later
destination hooks; raw/ICMP/SCTP sockets are refused. A positive result from B still permits other installed filters
to refuse that operation.

Processes with another real UID and valid listed-app tags continue to the existing filters. There is no exemption
for owner cron/at jobs or user services, or for a setuid process whose real UID is still the owner. In particular,
network-dependent sudo authentication may break. No path, name, cgroup, `node`, `blackice` or agent exception exists.

AF_UNIX is not hooked. Accepted inbound connections and sockets connected before arming remain outside this
admission boundary. The DNS stub is a two-way data channel. Listed executables can be launched with different
arguments or injected into by owner-UID code. Privileged daemons reached over Unix sockets can perform network
work for the caller. This is intended as an ordinary-app network control, not an exfiltration boundary.

Unlisted browsers, chat/mail clients, owner-run updates and development tools, localhost clients, rootless
container relays, agent sessions and blackice task proxies would lose new network access. **Do not enable this on
a machine running agent sessions.** A separate exception design would need its own review.

## Runtime work required before lifting the gate

1. Integrate and verify the inactive adapter, without altering base program bytes or tag maps. The base loader
   currently requires exactly one root attachment: restart verification must account for verified B IDs, while
   continuing to refuse foreign IDs. Five hooks mean five attachments, not one literal program ID. The adapter
   deliberately has no activation API until recovery and receipt accounting are complete.
2. Add a root-owned timer/service outside `user.slice`, with a narrow fixed-unit authorization path from the
   dedicated service account. It must operate after service death. Use a separate bounded transition lock:
   the base service holds `instance.lock` for its entire lifetime. An old timer must not detach a new arming.
3. Implement owner-only, pidfd-based polkit confirmation and root `--emergency-off`, including exact detach,
   checked fallback, crash ordering, restart preservation and reboot disarm. Do not restart the try window.
4. Add bounded, single-writer refusal summaries, labeled `comm (process-chosen)` rather than executable identity.
   LRU map eviction has no automatic overflow count; select and review an accounting strategy before claiming one.
   Root recovery cannot append behind the active service log writer.
5. Run the exact reviewed artifact in the designated VM, including a graphical console. This branch includes the
   base listener's TIME_WAIT recovery fix; unit tests and an SSH session do not prove console recovery.

## Acceptance evidence still required

Every row below is **NOT RUN**. The identity preflight does not satisfy any enforcement row.

| Case | Required observation |
| --- | --- |
| T1: listed ceiling | Narrow listed curl works; an unlisted copy fails; record `ptrace_scope` and exec/injection limits. |
| T2: Unix services | Owner groups recorded; AF_UNIX works; privileged-daemon delegation remains a declared limit. |
| T3: DNS channel | UDP exact stub works; TCP stub, adjacent resolver, other loopback and DoH fail. |
| T4: machine footprint | Other UIDs, root/system services, login screen and inbound SSH retain baseline behavior; owner cron/at/user services fail. |
| T5: recovery | No confirm expires after five minutes; confirm persists; kill service/socket and observe both kernel expiry and root detach; old timer/rearm race is harmless. |
| T6: receipt limits | Refusal flood remains bounded and responsive; truthful overflow; process-chosen label; no authenticated-path claim. |
| T7: console lockout | From the VM's graphical console, open a terminal and recover with sudo and polkit while B is armed. |
| Connection/reboot limits | Existing/inbound sockets behave as declared; suspend consumes the boot deadline; reboot starts disarmed. |
| Cleanup | Only B IDs disappear on B-only revert; base program IDs/tags stay unchanged; full off cleans its exact owned pins. |

The future enforcement harness must stop before privilege on any guest identity mismatch or failed recovery control.
It must retain raw logs, artifact hashes, source commit, kernel/BTF identity, actual setup output and cleanup status.
This branch currently supplies only the identity preflight, not that enforcement harness.
