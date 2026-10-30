# URLSession evidence probe

`BlackiceProbe.app` is a small, separate app with signing identifier
`com.valentorassa.blackice.probe`. Its own executable makes foreground
`URLSession` requests. It has no filter, system-extension or App Sandbox
entitlements and does not share a process with the filter host. It can later be
signed with the owner's Developer ID Application certificate.

There is **one production executable**:
`BlackiceProbe.app/Contents/MacOS/BlackiceProbe`. Normal launch with no arguments
shows the window; passing one to three HTTPS URLs selects the CLI. Both paths
call the same `ProbeFetch` URLSession implementation compiled into that binary.
There is no separate CLI helper or different binary for the video. The defaults
are Service at `https://example.com/` and Telemetry at
`https://httpbingo.org/status/200`.

Current state: source prepared, **not yet compiled or run**; the Mac was
unreachable during this change. No window was opened and no request was made by
the probe. Signing, notarization, actual transport and filter enforcement remain
unverified.

Build and test with Command Line Tools, without launching a window:

```sh
PROBE_WORK="$(mktemp -d /private/tmp/blackice-probe.XXXXXX)"
./macos/build-probe.sh "$PROBE_WORK/build"
./macos/test-probe.sh "$PROBE_WORK/tests"
"$PROBE_WORK/build/BlackiceProbe.app/Contents/MacOS/BlackiceProbe" --help
"$PROBE_WORK/build/BlackiceProbe.app/Contents/MacOS/BlackiceProbe" --check https://example.com/ https://httpbingo.org/status/200
```

These are separate targets; `build.sh` and `test.sh` still build/test only the
filter and host. `test-probe.sh` tests argument rejection and transport-result
classification without AppKit, networking, authentication or filter operations.
Neither build script calls `codesign` or runs the probe. Output directories must
belong to the current user and must not be group/other-writable. Keep this shell
and `PROBE_WORK` for the configuration step; do not substitute a shared path.

After the signed-run gate, the same executable makes one to three sequential requests:

```sh
/Applications/BlackiceProbe.app/Contents/MacOS/BlackiceProbe https://example.com/ https://httpbingo.org/status/200 https://example.com/
```

Each result is one JSON line labeled `kind: "probe_result"`, with a request
label, host, HTTP status or error outcome, protocol, TLS/fresh-connection checks,
start/completion UTC timestamps and elapsed time. URLSession errors also carry
their numeric code. Output follows input order, including repeated URLs. A CLI
watchdog timeout emits `outcome: "watchdog_timeout"`, cancels that session and
continues to the next URL; a late callback cannot print a duplicate result. It
does not invent an HTTP status or an unobserved byte count.
It is a client observation, **not a filter receipt**. A failed request must match
a provider denial before claiming enforcement. Exit 0 means every result was
2xx with verified transport; a failed or unverified request returns 1; invalid
arguments return 2. With no arguments (or `--gui`), the app presents Service and
Telemetry buttons. `--gui SERVICE_URL TELEMETRY_URL` chooses different endpoints.
The window makes no request until a button is clicked; it disables both buttons
until the active request finishes. Telemetry is an explicitly labeled test role,
not actual analytics collection. Requests carry no telemetry payload.

Each request uses a fresh ephemeral session, no cookies/cache/credential storage,
normal OS server-certificate validation, no HTTP/client-certificate
authentication, and no redirects. Only HTTPS DNS names on port 443 are accepted;
userinfo, query strings and fragments are rejected. Response bodies are counted
and discarded, with cancellation after 64 KiB. Request/resource timeouts are
15/20 seconds; the CLI has an additional 25-second watchdog per request. The
result guarantee applies to valid input while the process runs; a launch
rejection, crash or OS kill can leave no result and must be recorded separately.

Transport is checked, not assumed. `assumesHTTP3Capable = false` prevents opting
into QUIC racing without discovery; it **does not disable discovered HTTP/3**.
See Apple's [property contract](https://developer.apple.com/documentation/foundation/urlrequest/assumeshttp3capable).
The probe accepts success only when `URLSessionTaskMetrics` records one fresh,
non-proxied network transaction using `http/1.1` or `h2` with negotiated TLS.
HTTP/3, unknown/missing metrics, reused connections, proxies and cached results
produce `transport_unverified`. Use endpoints without HTTP/3 advertisement for a
controlled TCP-only evidence run; the default public endpoints are convenience
targets, not transport-qualified fixtures. The filter also denies UDP/QUIC under
domain rules. No private URLSession API or OS HTTP/3 setting is changed.

## Keep GUI and command-line evidence on the same build

Record the executable SHA-256 and bundle cdhash of the installed signed probe
used by both modes. These are read-only inspection commands, for the later
signed-run gate:

```sh
PROBE_APP=/Applications/BlackiceProbe.app
PROBE="$PROBE_APP/Contents/MacOS/BlackiceProbe"
shasum -a 256 "$PROBE"
/usr/bin/codesign -dv --verbose=4 "$PROBE_APP" 2>&1 | awk '/^(Identifier|TeamIdentifier|CDHash)=/'
```

For a renamed-copy test, copy the **whole signed bundle** into a private
workspace, without rebuilding or signing it again, then invoke its same
`Contents/MacOS/BlackiceProbe` executable. The renamed bundle's executable hash
and cdhash must match the original; validate the copied bundle's signature too.
Changing its enclosing path does not require a different CLI. The single-URL
form supports the tampered-copy attempt:

```text
/path/to/copy.app/Contents/MacOS/BlackiceProbe https://example.com/
```

If macOS refuses or kills a tampered copy before it runs, record that OS outcome,
not a fabricated probe line or filter denial. No copy/tampering/signing test or
window launch has been performed by this preparation. The default 20-second
resource timeout and 64 KiB limit also bound any slow-download evidence; qualify
the fixture and timing before relying on it to span an authenticated update.

## Policy and evidence

After obtaining the real Team ID, use the unsigned host's read-only `make-config`
command to embed `probe-service-only.json` exactly:

```sh
: "${PROBE_WORK:?Run the private-workspace setup above}"
./macos/build/Blackice.app/Contents/MacOS/BlackiceApp make-config macos/Examples/probe-service-only.json TEAM_ID com.valentorassa.blackice.probe app-probe allow os-metadata > "$PROBE_WORK/apps.json"
./macos/build/Blackice.app/Contents/MacOS/BlackiceApp validate "$PROBE_WORK/apps.json"
```

Replace `TEAM_ID` with the enrolled ten-character ID; the literal placeholder
is intentionally rejected. The policy allows `example.com:443` and excludes
`httpbingo.org`; **unmatched apps are allowed**. When the filter is active and
the probe is Developer ID signed, the intended comparison is Service, Telemetry,
Service, correlated with provider receipts. An unsigned/ad hoc probe follows
`unmatched` and cannot prove the bound-app policy. The owner-readable receipt
file is required for that comparison and awaits security design review.

One result per URL is not a guarantee of one OS socket per URL. Keep all flow
receipts: IPv4/IPv6 racing, retries and HTTP/3 fallback can produce additional
attempts, and a DNS or TLS failure is not automatically a filter denial. The
strict one-to-one evidence case needs an isolated, controlled TLS/TCP run with
exactly one attributable decision per result and no loss or uncertainty. Match
scope, generation, host/destination and the timestamps; retain extra/missing
matches and mark the case unqualified instead of deleting records. Apple's
[networking guidance](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
and [transaction metrics](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics/transactionmetrics)
describe the connection-selection and per-transaction behavior underlying this
qualification. Probe observations are not an audit authority.

For one wrapper containing both apps and an explicit update generation, see the
[multi-app recipe](../Examples/README.md#probe-and-netnewswire-in-one-configuration).
It keeps policies as separate files and computes their embedded hashes.

Use NetNewsWire as the first native-app candidate. Its
[download implementation](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/RSWeb/Sources/RSWeb/DownloadSession.swift)
uses an ephemeral `URLSession`. This is source evidence only: qualify the
installed release's exact Team ID/signing identifier, source-app/process
attribution, `remoteHostname` and TLS/TCP flows before accepting it as evidence.
Start with public feeds at `https://www.swift.org/atom.xml` and
`https://netnewswire.blog/feed.xml`, using `netnewswire-feeds.json`; additional
redirect, icon and update hosts need discovery and explicit policy decisions.
No sign-in or personal account is needed for its local feed mode. Add a second
native app only after the same checks; Chrome, Electron, Firefox and Apple's
own apps are not per-domain evidence targets for this version.

## Later signing, after enrollment and security review

The probe needs no Network Extension profile or capability. Use a fresh build
and the same enrolled Developer ID Application identity; do not use ad hoc
signing for evidence. `sign-notarize.sh --probe-app` prepares both apps together,
with separate submission and final archives. The host and extension keep their
own profiles; the probe gets neither profile nor Network Extension entitlement.
These commands have **not** been run:

```sh
PROBE_SIGN_WORK="$(mktemp -d /private/tmp/blackice-probe-sign.XXXXXX)"
./macos/build.sh "$PROBE_SIGN_WORK/host-build"
./macos/test.sh "$PROBE_SIGN_WORK/host-tests"
./macos/build-probe.sh "$PROBE_SIGN_WORK/probe-build"
./macos/test-probe.sh "$PROBE_SIGN_WORK/probe-tests"
./macos/sign-notarize.sh \
  --team-id TEAM_ID \
  --identity 'Developer ID Application: OWNER NAME (TEAM_ID)' \
  --host-profile /absolute/path/Blackice-Host.provisionprofile \
  --extension-profile /absolute/path/Blackice-Filter.provisionprofile \
  --keychain-profile blackice-notary \
  --app "$PROBE_SIGN_WORK/host-build/Blackice.app" \
  --probe-app "$PROBE_SIGN_WORK/probe-build/BlackiceProbe.app" \
  --output "$PROBE_SIGN_WORK/notarized"
```

Replace placeholders only after enrollment and security review. The script
checks both input trees, prints their unsigned executable hashes, and uses only
the named keychain profile for notary authentication. Each app must get an
`Accepted` result before it is stapled, signature-checked, assessed by Gatekeeper
and staple-validated. The final `Blackice-notarized.zip` and
`BlackiceProbe-notarized.zip` are made after stapling. A failure stops the command;
partial output is not a completed two-app release. Installation and opening the
window remain separate owner actions.

Recovery from an active filter is the signed host command
`/Applications/Blackice.app/Contents/MacOS/BlackiceApp disable`, with local
Touch ID/password approval. Keep a local terminal available for evidence runs.
To deactivate the extension itself, use
`/Applications/Blackice.app/Contents/MacOS/BlackiceApp deactivate`. See
[the filter guide](../../docs/macos-app-filter.md#defaults-and-recovery) for the
targeted `systemextensionsctl` fallback, the unverified Recovery-mode limit, and
the existing-flow, helper, DNS and provider-downtime limits.
