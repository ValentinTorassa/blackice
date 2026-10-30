# URLSession evidence probe

`BlackiceProbe.app` is a small, separate app with signing identifier
`com.valentorassa.blackice.probe`. Its own executable makes foreground
`URLSession` requests. It has no filter, system-extension or App Sandbox
entitlements and does not share a process with the filter host. It can later be
signed with the owner's Developer ID Application certificate.

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

After the signed-run gate, the CLI makes two or three sequential requests:

```sh
/Applications/BlackiceProbe.app/Contents/MacOS/BlackiceProbe https://example.com/ https://httpbingo.org/status/200 https://example.com/
```

Each result is a JSON line labeled `kind: "probe_result"`, with a host, HTTP
status or numeric error, protocol, TLS/fresh-connection checks and elapsed time.
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
15/20 seconds; the CLI has an additional 25-second watchdog per request.

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
signing for evidence. The filter's `sign-notarize.sh` handles `Blackice.app`
only; this separate ordinary app has the following owner-operated recipe.
These commands have **not** been run:

```sh
PROBE_SIGN_WORK="$(mktemp -d /private/tmp/blackice-probe-sign.XXXXXX)"
./macos/build-probe.sh "$PROBE_SIGN_WORK/build"
PROBE_APP="$PROBE_SIGN_WORK/build/BlackiceProbe.app"
/usr/bin/python3 -I macos/Signing/private_paths.py tree "$PROBE_APP"
shasum -a 256 "$PROBE_APP/Contents/MacOS/BlackiceProbe"
/usr/bin/codesign --force --options runtime --timestamp --sign 'Developer ID Application: OWNER NAME (TEAM_ID)' "$PROBE_APP"
/usr/bin/codesign --verify --strict --deep "$PROBE_APP"
/usr/bin/ditto -c -k --keepParent "$PROBE_APP" "$PROBE_SIGN_WORK/submission.zip"
xcrun notarytool submit "$PROBE_SIGN_WORK/submission.zip" --keychain-profile blackice-notary --wait
```

Only after the response explicitly says `Accepted`, staple and verify:

```sh
xcrun stapler staple "$PROBE_APP"
/usr/bin/codesign --verify --strict --deep "$PROBE_APP"
/usr/sbin/spctl -a -vv --type execute "$PROBE_APP"
xcrun stapler validate "$PROBE_APP"
/usr/bin/ditto -c -k --keepParent "$PROBE_APP" "$PROBE_SIGN_WORK/BlackiceProbe-notarized.zip"
```

Stop on any failed command. The final archive is made after stapling. Installation
and opening the window are separate later owner actions; this recipe does neither.

Recovery from an active filter is the signed host command
`/Applications/Blackice.app/Contents/MacOS/BlackiceApp disable`, with local
Touch ID/password approval. Keep a local terminal available for evidence runs.
To deactivate the extension itself, use
`/Applications/Blackice.app/Contents/MacOS/BlackiceApp deactivate`. See
[the filter guide](../../docs/macos-app-filter.md#defaults-and-recovery) for the
targeted `systemextensionsctl` fallback, the unverified Recovery-mode limit, and
the existing-flow, helper, DNS and provider-downtime limits.
