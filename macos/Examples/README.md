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
