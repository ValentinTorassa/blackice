# App filter examples

Every wrapper or `make-config` example defaults to **`unmatched: allow`**. The
network policy describes destinations; the separate `blackice.appscope/v0`
wrapper names the app with its exact Team ID and signing identifier. Do not add
app-selector fields to the unchanged `blackice.policy/v0` format.

| Policy/configuration | Named app | Purpose |
| --- | --- | --- |
| `probe-service-only.json` | Blackice Probe, `com.valentorassa.blackice.probe` | Allow `example.com:443`; exclude the `httpbingo.org` test role. Bind the enrolled owner's actual Team ID. |
| `netnewswire-feeds.json` | NetNewsWire | Starting policy for public Swift/NetNewsWire feeds; inspect the installed app's exact signing identity and discover its actual hostnames before binding it. |
| `demo-apps.json` | Firefox (`app-firefox`) and VS Code (`app-vscode`) | Legacy syntax fixture with explicit identity pairs and embedded policy hashes; **not per-domain evidence** for these networking stacks. |
| `firefox-mozilla-only.json`, `vscode-without-crash-telemetry.json` | The matching app in `demo-apps.json` | Original policy-byte fixtures used by that wrapper; no claim of live enforcement. |
| `deny-all.json`, `allow-test-subnet.json` | The synthetic `com.example.probe` binding in the guide | Parser/evaluator fixtures; the subnet example uses documentation addresses. |

The [probe guide](../Probe/README.md#policy-and-evidence) shows how to build the
named probe wrapper without activating it. No example invents Valen's Team ID or
an installed NetNewsWire identity. An unsigned/ad hoc probe follows unmatched
allow and cannot prove an app binding.

## Probe and NetNewsWire in one configuration

Use the new read-only multi-app `make-config` form. This command path is prepared
but still awaits Mac compilation/tests. Set `PROBE_TEAM_ID` from the enrolled
identity and `NEWS_TEAM_ID`/`NEWS_SIGNING_ID` from the actual NetNewsWire signature,
as shown in the [filter guide](../../docs/macos-app-filter.md#probe-and-native-app-demo).
These identifiers are public selectors, not credentials. The following only
writes and validates a configuration, without enabling it:

```sh
: "${PROBE_TEAM_ID:?Set the enrolled probe Team ID}"
: "${NEWS_TEAM_ID:?Inspect NetNewsWire's actual Team ID}"
: "${NEWS_SIGNING_ID:?Inspect NetNewsWire's actual signing identifier}"
MULTI_WORK="$(mktemp -d /private/tmp/blackice-multi.XXXXXX)"
APP=./macos/build/Blackice.app/Contents/MacOS/BlackiceApp
"$APP" make-config --generation 2 --unmatched allow --hostname-mode os-metadata \
  --app macos/Examples/probe-service-only.json "$PROBE_TEAM_ID" com.valentorassa.blackice.probe app-probe \
  --app macos/Examples/netnewswire-feeds.json "$NEWS_TEAM_ID" "$NEWS_SIGNING_ID" app-netnewswire \
  > "$MULTI_WORK/apps.json"
"$APP" validate "$MULTI_WORK/apps.json"
jq '{generation, unmatched, hostname_mode, apps: [.apps[] | {scope, signing_id, policy: (.policy_json | fromjson | .network)}]}' "$MULTI_WORK/apps.json"
```

Generation 2 is an example, not an automatic read of installed state. Choose a
strictly higher generation for every update. After adding the previously denied
feed host to `netnewswire-feeds.json`, inspect the real source change and rebuild
the **whole** wrapper, keeping the probe binding:

```sh
git diff -- macos/Examples/netnewswire-feeds.json
"$APP" make-config --generation 3 --unmatched allow --hostname-mode os-metadata \
  --app macos/Examples/probe-service-only.json "$PROBE_TEAM_ID" com.valentorassa.blackice.probe app-probe \
  --app macos/Examples/netnewswire-feeds.json "$NEWS_TEAM_ID" "$NEWS_SIGNING_ID" app-netnewswire \
  > "$MULTI_WORK/apps-next.json"
"$APP" validate "$MULTI_WORK/apps-next.json"
```

The builder preserves each policy's bytes, recalculates its original-byte
SHA-256 and validates both bindings. Apply later with the signed host's `enable`
command and owner authentication; wait for `policy_activated`/`snapshot_installed`
at generation 3 before new requests. The required receipt-file output is still
pending; `preferences_saved` is not that acknowledgement. Already allowed
connections keep their verdict. The policy files remain ordinary
`blackice.policy/v0` files usable by task scopes too.

## Recovery

For local recovery from an installed filter, use the signed host:

```sh
/Applications/Blackice.app/Contents/MacOS/BlackiceApp disable
/Applications/Blackice.app/Contents/MacOS/BlackiceApp deactivate
```

Each command asks for fresh owner authentication; honor any restart request.
The [recovery guide](../../docs/macos-app-filter.md#defaults-and-recovery)
explains the targeted `systemextensionsctl` fallback and why Recovery-mode
removal remains a qualification gate. Do not default to `unmatched: deny`: it
can stop DNS and other system services for the entire Mac.
