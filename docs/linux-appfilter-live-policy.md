# Linux application policy reload (experimental VM build)

`blackice app reload --policy FILE` replaces an armed application configuration
without restarting the listed applications. This branch is for isolated VM
validation and security review. It is not cleared for a host installation and is
not part of the task-scope 0.1.0 release. `app reload --help` and `app status`
explicitly report `experimental_vm_only`.

Use a complete `blackice.apps/v0` configuration with `generation` equal to the
current generation plus one. Initial `app on --policy FILE` accepts generation 1
(or a legacy file with the generation omitted). Reload requires an explicit
integer, rejects missing/null/fractional/duplicate values, and stops at 256.
The embedded network policy retains its existing parser and semantics.

```sh
blackice app status
blackice app reload --policy apps-generation-2.json
```

The caller must be the configured owner, identified through SO_PEERCRED and
SO_PEERPIDFD. A tagged caller is refused before polkit and checked again after
it. Reload uses `org.blackice.appfilter.reload` with fresh `auth_admin`, never
`auth_admin_keep`. The CLI starts the existing terminal authentication agent.
A raw owner request without successful authentication is refused. There is no
client-supplied UID, PID, kernel file identity or generation override.

Only one change runs at a time. A temporary control acceptor refuses concurrent
requests with `ChangeInProgress` (or `TaggedCaller`); it cannot change policy,
authorize a caller, or write a BPF map. Stopping and unarmed services refuse reload.
A disconnected requester does not undo a committed change: check status and the
activation receipt before retrying.

## Commit and recovery

All maps, listeners, the task-iterator link, seven proxy receipt files and the two
policy pipes are opened before dropping load capabilities and forking. The child
keeps only its listener/log/channel descriptors, has no capabilities, and retains
the existing Landlock/seccomp restrictions. No reload creates a map, program,
link, listener, receipt file, or raises BPF/PERFMON capabilities.

The implementation uses an admission fence and generation-qualified immutable
rows, with this commit order:

1. Validate the complete configuration and canonical root-owned ELF identities.
   Reject inode aliases, exhausted slots, and an added executable already running
   untagged. The check reads the iterator link pinned at arming.
2. Persist the original configuration bytes under their SHA-256 and record the
   pending change. The child parses
   the bounded candidate and acknowledges preparation. A valid frame containing
   invalid policy JSON is refused while the old generation keeps serving.
3. Stage unreachable next-generation file/port rows,
   then fence new tagged kernel admissions and pause proxy admission.
4. Atomically persist and fsync authoritative intent, including ordered policy
   digests and retired slots. Publish the complete kernel epoch, then the child's
   whole policy snapshot. Existing process tags are never cleared or reassigned.
5. Publish service receipt context, record activation, resume the child, and open
   kernel admission. Recheck for untagged added processes and refresh identity
   watches. The state, proxy and service then name the committed generation.

Each socket hook captures the active hash entry once and uses that generation
for every subsequent lookup. Each proxy connection captures one immutable
binding at accept; hostname, port, resolved-address checks and its initial receipt
use that binding. Accepted/in-flight old decisions are not relabeled. The fence
can temporarily refuse new connections; it never provides an unfiltered path.
The existing unmatched behavior and the limitations below still apply.

The request header is 52 bytes, with a generation, SHA-256, command and bounded
body length. Configuration bodies are at most 1 MiB and nesting depth 32. The
only child answer is exactly 41 bytes: generation u64, digest 32 bytes, status u8.
Every answer must match the expected generation, digest and phase. Both pipes
are nonblocking; one total five-second parent deadline covers the exchanges,
including a full write pipe. There is no SCM_RIGHTS or variable-length child data.
Malformed/extra/stale answers, EOF, timeout or a post-prepare failure stop the
service and kill the child while preserving pins. Invalid framing/order also
terminates the child; a bounded policy-parse refusal is recoverable.

On restart, intent is authoritative. The service fences admissions, verifies and
loads its retained policy history, repairs missing committed rows, publishes the
intent's epoch and removes only unpublished future staging rows. It never clears
tags or previously published generations. A kernel epoch ahead of durable intent
is inconsistent with this protocol and refuses startup. The child starts with the
committed generation before admissions reopen. A pending change produces either
`policy_change_failed` / `interrupted` with both hashes, or
`policy_change_completed_after_restart` with both hashes. An intent/state crash
boundary therefore does not require those two digests to match at startup.

This is BPF map ABI 2. An existing ABI-1 installation must be turned off with its
original reviewed binary before upgrading. The new loader refuses incompatible
pins; it does not silently replace an active installation.

## Membership and existing connections

Slots remain bound to their original executable path throughout one arming.
Reordering the configuration does not reorder slots or their fixed ports.
An added app gets a previously unused slot. `CloseAddedAppsFirst` requires closing
its already-running untagged instance before retrying; the service cannot safely
retag an existing process and discover every descendant retroactively.

An executable can start between validation and kernel publication. The post-swap
scan reports `added_app_running_untagged` with its executable and TGID. Status
contains a slot bitmask; a pidfd keeps a discovered process flagged until it exits,
including after exec to another file. The scan cannot discover a descendant that
already changed executable before being observed. After a service restart it
rescans listed executable identities. Do not claim that live addition covers
those escaped descendants; close the application and its descendants first.

Removing an app omits its identity from future classification. Already tagged
processes keep their slot, old policy and old decision generation. Future launches
are unlisted. Retired slots are never reused within this arming, even after exit;
this deliberately stricter rule makes the seven-slot lifetime bound explicit.
Re-adding a retired path or replacing its inode requires an authorized off/on.
On a service restart, slots already retired are neither reused nor served; their
remaining tagged processes are refused. Apps retired later in that new service
lifetime still retain their last policy until another restart/off.

Open TLS and HTTP connections have a policy watchdog using the existing grant
watchdog's 200 ms polling and `SO_LINGER=0` reset mechanism. Widening preserves
allowed transfers. Narrowing rechecks the admitted SNI/Host, port and selected IP
against the current binding; newly refused connections are cut on both sides and
emit one `policy_changed` / `policy_narrowed` receipt with the new generation.
Scheduling and receipt I/O can add latency; this is not a real-time deadline.
Data already received by the client cannot be recalled. Name-based routing still
does not inspect encrypted HTTP content or eliminate domain fronting.

## Receipts and bounds

Service `policy_activated` carries the new `gen`, configuration `policy`, and full
`old_policy` / `new_policy` hashes. The bounded activation detail lists added,
removed, retired and changed paths.
Long summaries are truncated by the existing field cap; per-slot records retain
the corresponding executable independently. Each assigned app's proxy file receives
`policy_changed` with its old/new network-policy hashes and new generation.
Per-flow receipts carry an immutable policy/generation pair and executable.
Retired flows retain their previous pair. Kernel events carry their decision-time
generation; the reader resolves it through retained history, and UDP aggregation
flushes at generation boundaries instead of relabeling delayed events.

All seven proxy files are opened before sandboxing. A new slot writes
`slot_assigned` to its preopened file. The parent never writes those proxy files.
Published policy objects are retained until off/exit; at most 256 generations and
seven lifetime slots exist. Rejected, unpublished objects may be released.
Files use the existing 8 MiB ceiling and shared dropped-receipt counters; status
reports loss even when a full receipt file cannot contain another loss record.
The flat JSON schema is unchanged apart from optional old/new policy hashes.
The bounded event field is 64 bytes so the restart-completion event is not cut.

Map bounds are 4,096 file rows (including identity-watch aliases), 1,792 port rows,
one active epoch, seven candidate identities, eight scan results and the existing
fixed TGID tag array. Generation rows and retired slots are not recycled while
armed. Capacity exhaustion refuses/stops rather than widening enforcement.

## Validation

Run ordinary tests without privileges:

```sh
zig build test linux-appfilter-test linux-appfilter
python3 scripts/e2e/test_linux_appfilter_reload_vm.py
```

`scripts/e2e/linux-appfilter-reload-vm.py --help` describes the VM-only driver. It
arms once, reloads generations 2/3/4 through the actual owner CLI and polkit,
checks unchanged process tags/listener ports/attachments and matching state
hashes, and runs a 20 Hz direct-network refusal probe throughout. It needs a real
owner tty, four policies retaining its listed launcher, a dedicated off-VM
receiver, and a fresh output directory. An outside-scope control marker must reach
the receiver; the scoped marker must not. It never supplies passwords or installs
a polkit bypass. This fixed-membership driver is one acceptance test, not the
whole security gate.

Add `--web-loop` to run a second process through that same listed launcher. It
schedules 20 HTTPS requests per second alternating `example.com` and `github.com`,
with at most eight in flight, certificate verification and no client DNS/proxy
environment. The fixtures must use exact-name allowlists for those hosts. The
analyzer requires one initial proxy/kernel decision per completed attempt,
matching policy hashes and generations, observations of both names in every
generation, and no unexpected allowed-request failures or skipped schedule ticks.
An in-flight request reset by narrowing is counted separately from its initial
decision. Numeric dialing is intentional: the app filter must route by TLS SNI.

`scripts/e2e/linux-appfilter-reload-refusals-vm.py` checks an already armed VM
without a password: stale/invalid policies, raw unauthenticated owner, concurrent
request, root non-owner, tagged curl and a real terminal prompt cancelled with
Ctrl-C. It verifies unchanged kernel state and service PID plus refusal receipts.
It neither installs an auth rule nor exercises a successful reload.
With `--off-stopping` against the opt-in VM fault build, it additionally performs
a freshly authorized off interrupted after entering `stopping`, verifies reload
returns `Stopping` without changing that epoch, completes a second authorized
off, and verifies `NotArmed` plus the absence of pins. The owner-only test selector
is removed before retrying off; this option therefore changes VM state.

`scripts/e2e/linux-appfilter-reload-membership-vm.py` covers an already-running
untagged addition (refused), the later successfully added app's allow/deny flows,
a removed running process retaining its previous policy/generation, a fresh
unlisted launch reaching the controlled receiver, and a later app using a new
slot. It kills only the identified VM3 loader through a pidfd to check that a
retired process stays tagged but loses proxy service after restart. The script
uses real polkit for each reload/off and ends with an authorized off. Receiver
corroboration is required in addition to its local checks.

`scripts/e2e/linux-appfilter-reload-streams-vm.py` opens two real eight-second HTTPS
drip streams through the listed launcher. It requires widening to preserve both,
then narrowing to reset only the removed hostname within one observed watchdog
period, with exactly one `policy_narrowed` receipt at the new generation. The
still-allowed stream must continue transferring body bytes. Remote HTTP errors
and stalled endpoints fail the test; they are not enforcement evidence.

Run independent VM cases with a fresh systemd start budget. The unchanged
`StartLimitIntervalSec=600` / `StartLimitBurst=5` limit counts successful socket
activations too, including off-state status requests. A test operator may reset
the failed/start budget between isolated cases in VM3; the test drivers do not
reset it inside a case or hide a restart loop. Preserve any rate-limit failure
and its journal before rerunning. Do not loosen the installed unit's limit.

Crash testing has a separate opt-in build:

```sh
zig build linux-appfilter -Dappfilter-vm-faults=true
```

It refuses to run outside the designated `test3-vm`
guest and prints `VM-ONLY RELOAD FAULT BUILD`. Never use its binary or a bundle
containing it for a host installation. The default build compiles out all fault
file reads, pauses and signals. After separate VM-only installation and arming,
`scripts/e2e/linux-appfilter-reload-faults-vm.py --help` describes the controller.
It checks exact binary hashes and uses real owner-terminal polkit authentication.
Root creates an exclusive, non-symlink selector under `/etc/blackice-appfilter/`
containing the exact loader PID and one fault mode; a restarted PID ignores it.
The controller removes only its matching selector and leaves the recovered
generation armed. It does not install a polkit rule or handle a password.

The fault build can pause after added-app validation, after worker preparation,
after staging real next-generation map rows, or after the fsynced intent but
before kernel publication. The staged-row case checks that recovery removes
uncommitted future keys from both files and ports maps. A pause affects only
the transaction thread, so the concurrent-request refuser remains testable.
Pauses expire after 60 seconds and do not renew the five-second exchange budget.
The controller covers both crash boundaries, child death, a stopped child (the
real five-second timeout), and an invalid policy inside a valid prepare frame.
Its `after_validation` mode requires a candidate adding `/usr/bin/sleep`: it
launches an untagged instance during the pause, checks the warning/status flag,
verifies a post-publication launch is tagged, and checks that the warning clears
when the original process exits. Journal cursors prevent stale pause markers
from satisfying a later run.
It requires the appropriate interrupted/completed/refused receipt and unchanged
or advanced intent generation. A successful subsequent retry and removal/retirement
coverage remain separate requirements; compiled scripts alone are not evidence.

Before host use, evidence must also cover add/remove membership and its race,
slow allowed/revoked transfers, stale/malformed/oversized input, cancelled and
unauthenticated/tagged/non-owner requests, concurrent/off/unarmed rejection,
child failure/timeouts, both sides of the intent commit crash boundary, a
successful retry, and two reproducible builds. VM evidence and security clearance
are required; passing pure tests alone is insufficient.
