# P0-01: a binary signed with our Team ID is refused in block-all, and curl with a rule still works (macOS)

**Claim.** With the signed and notarized blackice extension active, a small binary signed with our Team ID and
named by no rule connected to pypi.org in accept-all and was refused in block-all, while the system `curl`, which a
rule allowed to reach pypi.org, got HTTP 200 in both modes. This is phase 0's check: "a small binary signed with our
Team ID is blocked by the extension and the rest of the Mac keeps working".

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled.

**Build.** Blackice.app 0.1.0, CFBundleVersion 2, built with `macos/scripts/build-app.sh` and signed by
`macos/scripts/sign.sh` with the Developer ID Application certificate of team M294LK997M (hardened runtime, secure
timestamp), then notarized and stapled. `systemextensionsctl` listed the extension as `0.1.0/2`. The commit and the
app's CDHash were not recorded.

**Configuration.** Written by the script:

```toml
# phase 0 check, written by macos/scripts/phase0-test.sh
mode = "accept-all"

[[allow]]
app = "com.apple.curl"   # Apple platform code: no team
hosts = ["pypi.org"]
```

**Run.** At the Mac, from Terminal:

```console
$ KEEP=1 macos/scripts/phase0-test.sh M294LK997M macos/build/sign-<time>/Blackice.app
```

The script signed the probe (`macos/scripts/probe.c`: one name lookup, then one TCP `connect` to port 443) as
`com.valentorassa.blackice.probe` with the team's Developer ID and checked that it reached pypi.org before blackice
filtered anything. It found the same build already in `/Applications` and reused it, ran `blackice start` with the
configuration above (Touch ID; generation 2), and ran the probe and `curl https://pypi.org/` in accept-all. Then it
switched to block-all (Touch ID; generation 3), ran both again, and switched back to accept-all (Touch ID;
generation 4). With `KEEP=1` it left blackice installed in accept-all instead of rolling back.

**Result.**

| Mode | Probe (signed, no rule) | `curl` (rule for pypi.org) | Decided by |
|---|---|---|---|
| accept-all | connected, exit 0 | HTTP 200 | extension: `flow allow accept_all` |
| block-all | refused: `connect pypi.org:443 failed: Bad file descriptor`, exit 1 | HTTP 200 | extension: `flow drop no_rule` for the probe, `flow allow rule_line_4` for `curl` |

Exit 1 is the probe's code for a refused connection; 2 would have meant the name lookup failed. The flow lines name
no app or host (both are private in unified logging), so they are matched to the probe and `curl` by their times:
the two `no_rule` drops came a second after block-all was installed, when the probe ran, and the allow came after
them, when `curl` ran. The probe opens one connection; the run does not show what the second drop was.

**Log lines.** The script's result, verbatim:

```
PASS  probe connects in accept-all (exit 0)
PASS  curl reaches pypi.org in accept-all (HTTP 200)
PASS  probe is refused in block-all (exit 1; 2 would mean DNS failed)
PASS  curl reaches pypi.org in block-all (HTTP 200)
```

The probe and the extension, from the run's output:

```
Identifier=com.valentorassa.blackice.probe
TeamIdentifier=M294LK997M
connect pypi.org:443 OK
blackice: start filtering (mode accept-all, 1 allow rule, 0 hooks, generation 2)
Network extension activated.
Filter saved and enabled: mode accept-all, 1 allow rule, 0 hooks, generation 2.
*	*	M294LK997M	com.valentorassa.blackice.filter (0.1.0/2)	Blackice Filter	[activated enabled]
		M294LK997M	com.valentorassa.blackice.filter (0.1.0/1)	Blackice Filter	[terminated waiting to uninstall on reboot]
probe exit 0, curl HTTP 200
blackice: change the mode from accept-all to block-all (generation 3)
connect pypi.org:443 failed: Bad file descriptor
probe exit 1, curl HTTP 200
blackice: change the mode from block-all to accept-all (generation 4)
```

The filter's unified log while block-all was on (times are UTC−3):

```
2026-11-03 00:49:13.203 Df com.valentorassa.blackice.filter[40727:29f4bd] [com.valentorassa.blackice.filter:control] control configuration_installed mode block-all, 1 allow rule, 0 hooks, generation 3
2026-11-03 00:49:14.298 Df com.valentorassa.blackice.filter[40727:29f4bd] [com.valentorassa.blackice.filter:flows] flow drop no_rule <private>
2026-11-03 00:49:14.301 Df com.valentorassa.blackice.filter[40727:29f4bd] [com.valentorassa.blackice.filter:flows] flow drop no_rule <private>
2026-11-03 00:49:15.227 Df com.valentorassa.blackice.filter[40727:29f4bd] [com.valentorassa.blackice.filter:flows] flow drop unknown_identity <private>
2026-11-03 00:49:15.259 Df com.valentorassa.blackice.filter[40727:2a010d] [com.valentorassa.blackice.filter:flows] flow allow rule_line_4 <private>
2026-11-03 00:49:15.851 Df com.valentorassa.blackice.filter[40727:29f4bd] [com.valentorassa.blackice.filter:control] control configuration_installed mode accept-all, 1 allow rule, 0 hooks, generation 4
```

**Recording.** None.

**Limits.**
- Block-all lasted under three seconds, and only the probe and `curl` were checked in it. "The rest of the Mac keeps
  working" rests on `curl` alone; other apps without a rule lost the network for those seconds, as block-all means.
- The `unknown_identity` drop at 00:49:15.227 is a process the extension could not identify; the run does not say
  which.
- The install step was not exercised: the same build was already in `/Applications` from an earlier attempt that
  night, and the rollback was skipped (`KEEP=1`).
- The commit and the CDHash of the build were not recorded. The earlier attempts that night failed for the reasons
  listed under phase 0 in `docs/plan.md` (notarization, `NSSystemExtensionUsageDescription`, the IPv4-mapped loopback
  rule); they are not recorded as entries.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 00:49 UTC−3 (03:49 UTC).
