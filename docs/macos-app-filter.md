# macOS application filter

State: **built, unsigned**. The Swift host and Network Extension compile with
Command Line Tools. The extension has **not** been installed, activated or tested
for live network enforcement. This is the application-scope backend; it does not
provide managed-command containment or a process-tree boundary.

## Build without Xcode

On a Mac with Command Line Tools:

```sh
./macos/build.sh
./macos/test.sh
./macos/build/Blackice.app/Contents/MacOS/BlackiceApp status
```

No packages or network downloads are required. The scripts use `xcrun swiftc`,
the macOS SDK and system frameworks. They target the current architecture and
macOS 13.0 or later (source-process audit tokens require macOS 13). Compilation
uses Swift 5 language mode on the installed Swift compiler, with warnings as
errors. This deployment target is not a claim of runtime qualification on every
macOS release.

`build.sh [output-directory]` requires a fresh app output path, so it cannot
accidentally preserve profiles or signatures from a previous signed build.
`test.sh [output-directory]` runs a standalone test executable; XCTest and full
Xcode are unnecessary. Build products are ignored by Git.

The output is:

```text
Blackice.app/Contents/
  Info.plist
  MacOS/BlackiceApp
  Library/SystemExtensions/com.blackice.app.filter.systemextension/Contents/
    Info.plist
    MacOS/BlackiceFilter
```

The Apple silicon linker can add an ad hoc execution signature. Here, **unsigned**
means no Developer ID identity, provisioning profile or Network Extension
entitlements. An ad hoc signature lets the host/test executable run locally;
it does not authorize a Network Extension. The build script never invokes
`codesign`, activates an extension, modifies filter preferences or changes SIP.

## Application identity and policy

`NEFilterDataProvider.handleNewFlow` evaluates new outbound IPv4/IPv6 TCP/UDP
socket flows. It takes an immutable configuration snapshot, resolves the OS
source-app audit token through `SecCodeCopyGuestWithAttributes`, checks dynamic
code validity against an Apple signing anchor, and verifies the signing
identifier and certificate Team ID. A path, bundle display name or PID alone
never authorizes an app. There is no positive identity cache or parent scan.

Bindings require an exact `team_id` and `signing_id` pair. Unknown, unsigned,
ad hoc, invalid or no-longer-resolvable source-app identities are denied even
when the configured unmatched action is `allow`. Apple platform processes
without a Team ID can be verified as known but cannot be explicitly enrolled by
this version's Team ID binding format. Other known identities follow the
explicit `unmatched` action and receive `outside_scope` receipts.

Source application and source process are recorded separately. A service may
create a connection for another app; its process identity does not replace the
source-app selector. See Apple's [audit token properties](https://developer.apple.com/documentation/networkextension/nefilterflow).
Helpers, interpreters and delegated traffic must be tested independently; a
binding to an app does not imply all descendants have that identity.

The network policy remains `blackice.policy/v0`, as defined in
`src/core/policy.zig`. It supports `deny-all`, `allow-all`, `allowlist`, exact
domains, `*.domain` subdomains, allow/deny CIDRs, and destination `ports`
(default `[80, 443]`; an empty array is invalid). Explicit subnet denies
win. Loopback, private, link-local, CGNAT and reserved addresses require an
explicit subnet allow. IPv4-mapped IPv6 destinations receive IPv4 checks, and
mapped CIDRs with a prefix of at least 96 normalize to IPv4. NAT64 destinations
are checked as both IPv6 and their embedded IPv4 address; 6to4, Teredo and other
transition addresses need an explicit subnet allow. Numeric/legacy IPv4 names
cannot satisfy domain rules.

The Swift evaluator preserves the policy's original UTF-8 bytes for the
SHA-256-based 12-character ID. It rejects unknown fields, duplicate JSON keys
(including escaped aliases), malformed patterns,
oversized/deep input, and unsupported app configuration fields. Configuration
limits are 1 MiB, 256 bindings, and 256 entries in each domain/subnet list.
As in the core, a null `ports` field uses the default. Other explicitly null
policy fields are invalid. Noncanonical dotted IPv4, including leading zeros,
is rejected before invoking the platform parser.

App bindings live in a separate `blackice.apps/v0` configuration. The helper
embeds each unmodified network policy as a `policy_json` string; it never asks
the provider to read a user-supplied file path:

```sh
APP=./macos/build/Blackice.app/Contents/MacOS/BlackiceApp
"$APP" make-config ./macos/Examples/deny-all.json ABCDE12345 com.example.probe app-probe allow ip-only > /tmp/apps.json
"$APP" validate /tmp/apps.json
```

The Team ID and signing identifier above are synthetic; substitute a real signed
probe before future activation. Both examples use documentation addresses;
`allow-test-subnet.json` is an evaluator fixture, not a real reachable service.

The generated shape is:

```json
{
  "version": "blackice.apps/v0",
  "generation": 1,
  "unmatched": "allow",
  "hostname_mode": "ip-only",
  "apps": [{
    "scope": "app-probe",
    "team_id": "ABCDE12345",
    "signing_id": "com.example.probe",
    "policy_json": "{\"version\":\"blackice.policy/v0\",\"network\":{\"mode\":\"deny-all\"}}"
  }]
}
```

Scope names start with `app-`. Duplicate scopes or identity pairs are rejected.
The provider validates the full candidate before installing a snapshot under a
lock. During a provider lifetime, a lower generation, or a different snapshot
at the same generation, is rejected. Invalid updates retain the last valid
snapshot. An invalid startup configuration fails startup; callbacks without a
snapshot deny. Generation monotonicity is in memory only; durable rollback
protection is not implemented.

## Destination coverage

`hostname_mode` must be explicit:

| Mode | Behavior |
| --- | --- |
| `ip-only` | Uses numeric socket endpoints and CIDRs. Rejects policies containing domain entries. |
| `os-metadata` | Uses `remoteHostname` when supplied, then checks the actual numeric endpoint. Without a name, uses IP-literal policy. |

The hostname is optional OS metadata, not an authenticated remote-service
identity. Apple's SDK documents it for flows from Network.framework and
NSURLSession. There is no DNS correlation, reverse lookup, SNI/HTTP inspection
or TLS certificate verification. A missing name cannot satisfy a domain rule;
a name without a numeric destination cannot authorize the flow. Malformed or
unsupported required data denies. Domain policies cannot promise universal
coverage or protection against a client supplying misleading hostname metadata.
See [`remoteHostname`](https://developer.apple.com/documentation/networkextension/nefiltersocketflow/remotehostname).

The native settings request callback delivery for normal traffic and explicitly
include loopback rules for `127/8`, `::1` and IPv4-mapped loopback. Apple's
[`NEFilterSettings`](https://developer.apple.com/documentation/networkextension/nefiltersettings)
defaults do not filter loopback. These rules still require real signed-run
qualification, including all loopback aliases and VPN interactions.

An allowed flow is allowed for its remaining lifetime. This implementation does
not inspect data or revoke already allowed sockets when policy changes. Traffic
that predates activation is unverified. Inbound flows are explicitly outside
scope. Unsupported socket families/protocols delivered for an enrolled app deny;
traffic not delivered by the OS cannot be claimed as covered. Local IPC, file
access, app tamper resistance and full descendant containment are separate gaps.

## Receipts and status

Decision receipts use the flat core schema: `ts`, `scope`, `policy`, `gen`,
`point`, `event`, `verdict`, `reason`, `rule`, `host`, `ip`, `port`, `detail`, with
optional `status` and `dropped` fields as in the core.
Absent optional values are omitted. Flow decisions use `point: "app_filter"` and
`detail` identifies `backend=network_extension;scope_kind=app`, the separate
validated app/process identities and hostname provenance.
Lifecycle/configuration events use `point: "control"`. String fields are cleaned
and capped at the same byte limits as the core; control and bidi characters
become `?`. Long identity labels retain a prefix and a hash of the complete label
so both app and process evidence fit within the detail field.

Currently the provider emits bounded JSON lines to unified logging under
subsystem `com.blackice.app.filter`, category `receipts`. It never writes the
Zig scope's `receipts.jsonl`. This preserves one writer per persisted scope.
There is no durable ingestion/acknowledgement bridge yet. Unified logging may
drop or truncate entries, and has no application-level loss accounting; these
diagnostics are **not** a complete audit trail. Logging failure never changes a
deny into an allow. No runtime receipts have been captured from this unsigned
build. After future activation, inspect diagnostic output with:

```sh
log stream --style json --predicate 'subsystem == "com.blackice.app.filter" AND category == "receipts"'
```

This command produces unified-log envelopes; the JSON receipt is in the message
field. The message is marked public for local collection and contains network
destinations and app identifiers; it does not contain payloads, complete URLs,
raw audit tokens, executable paths, credentials or environment variables.
Retention follows the OS logging policy. No broad log deletion is performed.

The host's `status` always reports `enforcement_verified: false` in this build.
Saving an enabled filter preference reports only `preferences_saved`. Neither
configuration save nor system-extension activation is an enforcement health
acknowledgement. Provider crash/suspension behavior, startup failure behavior
outside callbacks, and recovery remain runtime qualification gates.

## Signing, entitlements and installation

macOS content filters are deployed as system extensions inside a containing
app. Direct distribution supports Developer ID signing. See Apple's
[deployment matrix](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

For the intended Developer ID route, obtain Apple Developer Program membership,
a Developer ID Application certificate and profiles for two explicit App IDs:
`com.blackice.app` and `com.blackice.app.filter`. These are build identifiers,
not a claim that they have already been registered. If another prefix is needed,
update `AppFilterConstants`, both Info plists and the build's extension path
together before signing.

Enable the Network Extensions capability for both identifiers and System
Extension installation for the host, and generate matching Developer ID
provisioning profiles. Validate the actual profile entitlements against the
intended distribution route. Apple specifies the
[`content-filter-provider-systemextension` entitlement value](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
for Developer ID. `filter-data-provider-systemextension` is not the entitlement
value; `com.apple.networkextension.filter-data` is the Info.plist provider class
mapping key.

| Target | Required entitlement |
| --- | --- |
| Host | `com.apple.developer.system-extension.install = true` |
| Host and extension | `com.apple.developer.networking.networkextension = ["content-filter-provider-systemextension"]` |
| Both, when signing | Matching `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profiles |

The templates in `macos/Resources/*.entitlements` contain only the capability
keys; they are not provisioned identities. For release, prepare copies with the
real application identifiers and Team ID allowed by each profile. Do not assume
an account's App ID prefix is interchangeable with its Team ID. Embed each
profile as `Contents/embedded.provisionprofile` in its respective bundle.
Profiles, certificates and private keys stay outside Git.

Sign the nested `.systemextension` first and the host `.app` last, with the same
team's Developer ID Application identity, hardened runtime, secure timestamp,
and their respective final entitlements. Verify both signatures/entitlements,
then notarize and staple the distributed app. Full Xcode may simplify capability
and profile management; it is not needed for this unsigned compile. Ad hoc
signing, manually adding entitlement strings, and a free Personal Team do not
complete this Developer ID deployment path. See Apple's
[system extension installation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install)
and [notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

There is no Endpoint Security entitlement, app-group container or custom Mach
service in this implementation. Configuration travels through
`NEFilterManager.providerConfiguration.vendorConfiguration`; diagnostic receipts
use unified logging. A future durable control/receipt channel will need its own
authenticated transport and entitlement review.

After signing and notarization, install the host under `/Applications`, then
explicitly run the deployment helper from the bundle:

```sh
APP=/Applications/Blackice.app/Contents/MacOS/BlackiceApp
"$APP" activate
"$APP" enable /absolute/path/apps.json
"$APP" status
```

These are future deployment instructions, not steps performed by the build.
macOS must approve the system extension and the network filter; inspect the
normal System Settings prompts, or the corresponding managed deployment
authorization. A restart-required response is not treated as completed
activation. Keep SIP enabled and normal security settings. Never use developer
mode or disabled SIP as evidence of a supported installation.

`activate`, `enable`, `disable`, `remove-config` and `deactivate` refuse an
unsigned/ad hoc host. macOS additionally enforces entitlement/profile and user
consent requirements. `enable` refuses an already enabled configuration so a
policy change cannot be mistaken for immediate revocation of old sockets.
The helper rejects a configuration owned by a different provider identifier.

Recovery removes only this filter's configuration and extension:

```sh
"$APP" disable
"$APP" remove-config
"$APP" deactivate
```

Confirm the resulting state in System Settings and honor any restart request.
This restores the absence of this app's filtering, not a protection guarantee.
It neither flushes host firewall rules nor changes another filter. Local
diagnostic log retention is unchanged. Configuration management currently relies
on macOS authorization and a trusted local operator; it does not provide a
separate per-request owner-authentication protocol.

## Validation and remaining gates

Verified on 2026-10-30 on an arm64 Mac running macOS 27.0.1 (26A434), with SIP
enabled, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) and the Command Line Tools
macOS 27.0 SDK. Both bundles compiled with warnings as errors; the four resource
plists passed `plutil`; 140 test assertions passed. The host's `make-config` and
`validate` commands accepted both included examples, and `status` reported
`built, unsigned` with `enforcement_verified: false`. Signature inspection
confirmed only linker ad hoc signing with no Team ID. No activation or live
enforcement test was performed.

Tests cover exact/wildcard matching, private and mapped addresses, IPv6 CIDRs,
ports, malformed/duplicate/unknown configuration, identity binding isolation,
unknown-app denial, delegated-source handling, missing destination data,
snapshot generations and receipt encoding. The Security framework tests verify
rejection of missing/invalid audit tokens and the ad hoc test executable. They
do not substitute for a correctly signed app's runtime identity tests.

Before this app-scope backend can be called operational, record separate evidence
for normal-security signed activation; a signed probe launched outside blackice;
real allow/deny with an off-host receiver; direct TCP/UDP on IPv4/IPv6; loopback,
LAN, DNS and local proxies; unknown apps; PID reuse, exec and executable
replacement; helpers/interpreters and delegated services; existing sockets and
policy changes; crash/restart, sleep/wake, logout and VPN coexistence; recovery;
and durable receipt delivery with loss accounting. No four-cell release gate is
satisfied by compilation alone.
