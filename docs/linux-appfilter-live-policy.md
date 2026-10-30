# Linux app-filter reload: independent components, runtime unavailable

`blackice app reload --policy FILE` is **not enabled**. This branch prepares its
CLI, authorization action, receipt fields and kernel generation machinery. It
cannot perform a live reload, and must not be installed as a reload-ready build.
The separate proxy-child channel, its preopened receipt files, admission
coordination and crash recovery still require implementation and review.

This command is local and read-only: it does not connect to the service or prompt:

```sh
blackice app reload --help
```

It prints `availability=prepared_only`. A syntactically valid reload request
returns exit 125 with `ReloadNotReady`, before starting a polkit agent or opening
the control socket. The service also recognizes the bounded reload frame and
refuses it; it never responds with success for a change it did not perform.
`app status` reports `reload=prepared_only`.

The existing `on`, `off` and task-scope commands retain their behavior. Initial
application files without `generation` retain their legacy generation-1 meaning.
Reload requires an explicit integer `generation`, bounded to 1..256, and the
service checks it is exactly current+1. A fresh `on` only accepts generation 1.
Duplicate fields, non-integers and null/missing reload generations are refused.
The embedded network policy is parsed by the unchanged network-policy parser.

The prepared operation uses `org.blackice.appfilter.reload`, a distinct polkit
`auth_admin` action with no retained authorization. The wire implementation uses
the existing kernel-derived SO_PEERPIDFD subject. Only the configured owner can
reach the service request; tagged callers are refused before authorization and
checked again after reading the policy. There is no user-supplied UID or PID.
Because reload is gated, no actual reload authorization is requested yet. Pure
wire tests do not establish a successful or cancelled interactive-polkit test.

## Receipts

The shared JSONL emitter accepts an optional paired decision context: policy hash
and generation captured together. Delayed writers can use that context instead
of a log's later defaults. Existing task receipts omit the new optional fields.
Reload records use flat `old_policy` and `new_policy` fields, each bounded and
cleaned like other receipt strings. The activation helper checks exact successor
generation and two full lowercase SHA-256 values before writing
`policy_activated` with the new `gen` and `policy`.

No runtime activation record is emitted while reload is unavailable. A raw reload
request that reaches the service's reload handler records
`policy_change_refused` with the unchanged generation. Earlier peer/tag/header
refusals use the existing generic control record. The CLI's local refusal does
not invent a service receipt. UDP aggregation has a tested generation boundary:
it refuses a mismatched event without changing the batch. Kernel generation decoding,
historical per-app policy lookup and the batch-flush dispatch still need integration;
queued old kernel records must never be relabeled with the current generation.

## Candidate kernel generation scheme

The current loader still selects the original v1 map ABI and programs. The
candidate generation layout and map writer are separate, exercised by pure tests;
no build or test loads, attaches, pins or switches a BPF program. Existing v1 pins
must not be interpreted as the candidate ABI.

The candidate uses these maps, all created before dropping load capabilities:

| Map | Key | Value |
| --- | --- | --- |
| Active hash, one entry | zero | coherent state, generation, fence and configuration digest |
| Files hash, at most 1,792 entries | device, generation, inode | stable app slot |
| Ports hash, at most 1,792 entries | app slot, generation | four fixed listener ports and that slot's decision generation |
| Tags | unchanged TGID | unchanged app slot |

The sole writer stages a complete generation using insert-only entries. A failure
leaves the old active record untouched; unreachable partial rows cannot be reused
without explicit abort/crash reconciliation. The map writer validates generations,
slot identities, fixed ports and inode uniqueness before the first write. Old
published rows remain for the arming's lifetime, bounded by seven slots and 256
generations. There are no new capabilities or per-reload map creations.

A socket hook captures the active record once. Every subsequent lookup uses that
captured generation. Exec classification likewise captures one generation before
looking up the executable. Publishing the candidate replaces one hash element
while keeping admission fenced; it never clears a tag. New tagged admissions in
the application hook are refused while fenced, even with a full receipt ring.
The root listener guard remains a listener guard; this does not implement
deny-unlisted or close the documented system-slice gaps.

Linux documents atomic replacement of individual [hash entries](https://docs.kernel.org/bpf/map_hash.html),
while [array values](https://docs.kernel.org/bpf/map_array.html) need synchronization
for concurrent in-place access. Generation-qualified immutable rows use that
single-entry publication boundary for kernel decisions. This is **not** a
transaction spanning the proxy, service and disk: the coordinator must fence the
proxy, persist authoritative intent, publish coherent state and verify all layers
before reopening admission. That coordinator is not implemented.

The candidate stores event-time generation in the first previously reserved word
of each 64-byte kernel event. Retired slots preserve their original decision
generation in the ports row. This layout needs explicit ABI selection, pin
verification and receipt-reader integration before any live run. The service's
current v1 event reader has not been switched to it.

## App membership and connection decisions

The immutable snapshot planner preserves slots across configuration reordering.
Removed apps keep their last policy and generation for already tagged processes;
the candidate next-generation files map omits their identity, so future launches
are unlisted. Retired slots are never reused within an arming in this preparation.
They count toward the seven-slot bound. A new app gets an unused slot; a known
running untagged instance refuses the plan with `CloseAddedAppsFirst`. Inode aliases,
executable replacement and exhausted slots also refuse without changing the old
snapshot.

A scan is not sufficient to close a concurrent exec/fork race: an added executable
can launch and fork a descendant that execs another file before the scan. A pure
counterexample test preserves that limitation. Real running-file checks, a pinned
iterator, identity-watch reconciliation and membership-commit coverage are still
required. No live-add or live-remove safety claim follows from these tests.

One immutable snapshot covers all app listeners and is captured once per
connection decision. Old objects stay allocated while any worker can refer to
them. Whether an already-open tunnel is reset when the new policy narrows access
is a separate pending security decision; this preparation neither implements nor
claims tunnel revocation. The worker protocol codec checks bounded 52-byte request
headers and exact 41-byte phase/generation/digest-bound replies. No child pipes or
new receipt descriptors have been added.

## Validation and remaining runtime gates

```sh
zig build linux-appfilter-test test
PYTHONDONTWRITEBYTECODE=1 python3 scripts/e2e/test_linux_appfilter_reload_vm.py
```

Tests execute the actual candidate BPF instructions in a userspace interpreter,
including replacement immediately after the active-state lookup, retired slots,
missing rows, fences and ring loss. The map writer's failure tests inject a fault
at each staging write and publication. These are not Linux-verifier or kernel
runtime results.

`scripts/e2e/linux-appfilter-reload-vm.py` is a prepared guest driver. It requires
an explicit `availability=ready` from the CLI before attempting to arm. This branch
therefore exits 77 without prompting, connecting to the service or creating a run
directory. Builds and unit tests never run its privileged/read-only bpftool calls
or its on/reload/off sequence.

When runtime integration is ready, that driver uses four fixed-membership
fixtures, arms once and reloads three times while recording direct TCP denials,
receipts, state, ports, files, stable tags and attachments. Off-VM receiver controls
are separately mandatory. It does not test proxy allow-list changes or an open
transfer; those need positive/negative TLS requests and a long-lived connection.
Membership races, unauthorized requests, child timeout/death, pinned iterator
reuse and every durable-intent crash boundary remain mandatory guest cases.
Use VM3 for this work; base-install tests own VM2. No host readiness or no-gap
runtime claim is made by this branch.
