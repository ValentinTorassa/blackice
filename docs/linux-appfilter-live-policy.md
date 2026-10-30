# Linux app-filter reload: preparation, not a released feature

`blackice app reload --policy FILE` is **not implemented in this branch**. Do not
install this branch to obtain reload. The service, CLI, BPF programs and setup
files are unchanged from the base. The new code is imported only by unit tests.

The proposed operation is an owner-authorized replacement of the entire app
configuration, with generation exactly N+1 and a maximum of 256 generations per
arming. The existing SO_PEERCRED/SO_PEERPIDFD check, tagged-caller refusal and fresh
polkit authorization must apply. Merely being an untagged process with the owner's
UID is insufficient. A new pair of pre-fork pipes would carry bounded requests
and fixed-size replies; it must add no capabilities to the proxy or loader.

The included pieces are:

- `reload_snapshot.zig`: immutable whole-generation snapshots and stable executable
  slots. One atomic pointer covers all apps/listeners. A connection captures it
  once for its port, name, address checks and receipt metadata. Paths, policies and
  snapshots must remain allocated until the worker exits. Nothing frees an old
  policy while an old connection can still refer to it.
- `reload_protocol.zig`: a 52-byte request header with a bounded policy body, and
  an exact 41-byte worker reply (generation, digest, status). Unknown values,
  truncation, surplus bytes, stale replies, phase and digest mismatches are rejected.
  Runtime transport still needs one five-second deadline for the entire exchange,
  the existing depth check before JSON parsing, descriptor allowlisting and worker
  death handling. Encoding tests do not establish those runtime properties.
- `reload_transaction.zig`: a pure ordering model. It refuses publication before
  kernel and proxy admission are fenced, and refuses to reopen admission until
  durable intent, kernel state, service state and proxy snapshot agree. Its methods
  represent effects a future runtime must actually verify; calling a method is not
  proof that a kernel fence or authentication exists.

Proposed connection behavior: an already accepted connection retains its original
policy and generation until it closes. A new connection after commit uses N+1.
This deliberately does not revoke an existing allowed tunnel on narrowing. It is
one of the supported design choices for this work, but differs from the separate
reset-on-narrowing proposal and still requires security review. No running behavior
has changed in this branch.

For membership changes, the planner keeps an app's slot when configuration order
changes. A removed app's running tagged processes retain the old policy and
generation; its slot is retired for the rest of that arming and never assigned to
another executable. Future launches become unlisted only after a successful
membership commit. A new app needs an unused slot, and a known already running
untagged instance rejects the request with `CloseAddedAppsFirst`. Inode aliases,
executable replacement, retired-path reuse and slot exhaustion also reject the
plan without changing the previous snapshot. These are planner tests, not kernel
evidence that live membership changes work.

The missing safety work is substantial. The existing loader replaces `files`
entries individually and updates a mutable array `state` record, while the proxy
is a separate process with no live input. A proxy-first update followed by map and
intent updates has an interval with different generations visible in each layer.
Adding a generation field to that array does not make the whole operation atomic.
Linux documents atomic replacement of individual [hash-map elements](https://docs.kernel.org/bpf/map_hash.html)
and synchronization requirements for [array values](https://docs.kernel.org/bpf/map_array.html);
neither provides a transaction spanning two processes, multiple maps and disk.

Likewise, scanning for an added executable before inserting its `files` entry
leaves an exec/fork race. A second scan and a warning can report some missed tasks,
but cannot prove there was no unfiltered interval or recover a descendant that
already execed a different file. This branch does not call that atomic coverage.

Before enabling reload, implement and review an admission fence and generation
publication scheme that covers those races. Stage all dependencies while admission
is closed; retain every tag and the last safe policy on failure. Persist the new
intent before publishing the candidate, and reconcile maps from that authoritative
intent after a crash, including a crash between intent and pinned-state writes.
Resume only when all three layers agree. A missing/malformed child reply must kill
the child and retain the pins; it must not be treated as successful activation.

Receipts must capture the decision's generation and policy at acceptance, instead
of consulting a mutable log default later. `policy_activated` must carry the new
generation and both configuration hashes. Kernel records need an event-time epoch;
relabeling a queued old kernel event with the current generation is incorrect.
The receipt and kernel ABI changes are not implemented here.

Run pure tests with `zig build linux-appfilter-test`. The prepared
`scripts/e2e/linux-appfilter-reload-vm.py` runs inside a disposable VM with a
reviewed installation, four generation fixtures, a listed launcher and an
off-VM TCP receiver. It refuses to arm when the CLI does not advertise reload,
which is the expected result for this branch. It is not run by builds or unit
tests. Use VM3 for this work; the base-install tests own VM2.

That script captures state/ports/files and stable process tags, arms once, attempts
three successive reloads, checks activation hashes and decision generations, and
keeps a tagged direct-connect loop running throughout. A receiver-side log and
out-of-scope controls must corroborate that no denied payload arrived. Finite
sampling can show an observed gap; it cannot prove the absence of every possible
gap without the implementation invariants. Its probe uses a fixed app membership
and direct TCP denials; it does not exercise the proxy's per-app domain changes or
the proposed preservation of already-open tunnels. Those need separate positive
and negative TLS requests and a long-lived transfer across narrowing. Kernel fault injection, membership
races, unauthorized control frames, worker timeouts and crash reconciliation
remain additional mandatory VM cases. No live-reload, no-gap or host-readiness
claim is made by the pure tests or by the prepared script.

The analyzer's synthetic tests run separately with
`PYTHONDONTWRITEBYTECODE=1 python3 scripts/e2e/test_linux_appfilter_reload_vm.py`.
They verify that missing, duplicated, mismatched or lost observations cannot
produce a passing report; they are not traffic or kernel evidence.
