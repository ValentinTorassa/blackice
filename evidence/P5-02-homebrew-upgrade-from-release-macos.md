# P5-02: blackice 0.1.0 installed with Homebrew from the published release, as an upgrade from build 4 (macOS)

**Claim.** On a Mac that had build 4 installed by hand, `brew trust` and `brew install --cask` installed blackice 0.1.0
(build 5) from the v0.1.0 GitHub release through the tap `valentintorassa/tap`. The installed app verified as signed
by team M294LK997M, notarized and accepted by Gatekeeper, and Homebrew's `blackice` command ran it. The install
guide's example configuration validated, and `blackice start` replaced build 4's extension with build 5's. As after
the upgrade from build 3 to build 4, the upgraded extension did not answer over XPC: `start` said so and exited with
status 75, the check added for this. After a restart, build 5's extension was the only one, its XPC service answered
`blackice pending`, and connections went through. This bears on phase 5's check, an install from the published
package by following `install.md`. It covers the Homebrew path as an upgrade, not a first install or an uninstall.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. Homebrew
7.0.12.

**Build.** Blackice.app 0.1.0, CFBundleVersion 5, from the v0.1.0 release
(`Blackice-0.1.0.zip`, SHA-256 `f7d5280aba612ad8d7894adedac4931b9322ab6d5f2b0e84e56f574d48482c57`). Built with
`macos/scripts/sign.sh` from commit 7952f38, whose `macos/` and `integrations/` are the same as the release tag's;
Developer ID signed (team M294LK997M), notarized and stapled, then zipped and checked by `macos/scripts/package.sh`.
Before the run, build 4 (P2-02) was installed in `/Applications` by hand and active, in accept-all.

**Configuration.** The example from step 3 of [`docs/install.md`](../docs/install.md), written to
`~/.config/blackice/blackice.toml`:

```toml
mode = "accept-all"     # "accept-all", "ask" or "block-all"
timeout_seconds = 60    # in ask mode, no answer in time means deny

# Permanent rules: one app, by signing identifier (and Team ID unless it is Apple's), and its hosts.
[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]
```

**Run.** A script at the Mac, started by a person, ran the steps of the guide's Homebrew section:
1. It waited until the release's `.sha256` file could be downloaded, which happened once the release was published.
2. `brew trust --cask valentintorassa/tap/blackice`, then `brew install --cask --force valentintorassa/tap/blackice`.
   `--force` because an app installed by hand was already in `/Applications`.
3. The checks of step 1 of the guide on `/Applications/Blackice.app`: `codesign --verify`, the identifier and Team
   ID, `stapler validate` and `spctl --assess`. Then `blackice status` through Homebrew's `blackice` command.
4. `blackice validate` on the example configuration, then `blackice start` (Touch ID, by the person).
5. The person restarted the Mac. Over SSH afterwards: `systemextensionsctl list`, `blackice status`,
   `blackice pending`, the extension's launchd job, and `curl` to pypi.org and api.github.com.

**Result.**

| Step | What happened | Decided by |
|---|---|---|
| Download | Homebrew downloaded the zip from the release and checked it against the cask's SHA-256. | Homebrew |
| Install | Homebrew replaced `/Applications/Blackice.app` and linked `blackice.wrapper.sh` as `/opt/homebrew/bin/blackice`. | Homebrew |
| Checks | build 5; `satisfies its Designated Requirement`; team M294LK997M; `The validate action worked!`; `accepted`, `source=Notarized Developer ID`. `blackice status` through the wrapper answered. | macOS |
| Start | Generation 26 saved; macOS activated build 5's extension and left build 4's `terminated waiting to uninstall on reboot`. `start` found no XPC service, printed its warning and exited with 75. | macOS, CLI |
| After the restart | Only build 5's extension, `activated enabled`. Its launchd job has the endpoint `M294LK997M.com.valentorassa.blackice.filter`, active. `blackice pending` answered with an empty list. `curl` got HTTP 200 from pypi.org and api.github.com. | extension |

**Log lines.** The script's checks, verbatim (escape codes removed):

```
== Before: the app installed by hand
/Applications/Blackice.app build 4
*	*	M294LK997M	com.valentorassa.blackice.filter (0.1.0/4)	Blackice Filter	[activated enabled]
== brew trust --cask valentintorassa/tap/blackice
Trusted cask: valentintorassa/tap/blackice
==> Installing Cask blackice
Warning: It seems there is already an App at '/Applications/Blackice.app'; overwriting.
==> Removing App '/Applications/Blackice.app'
==> Moving App 'Blackice.app' to '/Applications/Blackice.app'
==> Linking Binary 'blackice.wrapper.sh' to '/opt/homebrew/bin/blackice'
🍺  blackice was successfully installed!
== Check what Homebrew installed
version 0.1.0 build 5
/Applications/Blackice.app: satisfies its Designated Requirement
Identifier=com.valentorassa.blackice
TeamIdentifier=M294LK997M
The validate action worked!
/Applications/Blackice.app: accepted
source=Notarized Developer ID
blackice command: /opt/homebrew/bin/blackice
#!/bin/sh
exec /Applications/Blackice.app/Contents/MacOS/blackice "$@"
filter: enabled
configuration: mode accept-all, 1 allow rule, 1 hook, generation 25
```

`blackice start`:

```
blackice: start filtering (mode accept-all, 1 allow rule, 0 hooks, generation 26)
Activating the network extension. The first time, macOS asks you to allow it in System Settings.
Network extension activated.
Filter saved and enabled: mode accept-all, 1 allow rule, 0 hooks, generation 26.
This command does not verify enforcement; docs/phase-0.md has the check.
blackice start: the network extension was upgraded in place and its XPC service does not answer. On macOS 27 an upgraded extension can stay unreachable until the Mac restarts: restart it, or the daemon, pending, approve and deny cannot reach the extension and ask mode drops what it pauses.
*	*	M294LK997M	com.valentorassa.blackice.filter (0.1.0/5)	Blackice Filter	[activated enabled]
		M294LK997M	com.valentorassa.blackice.filter (0.1.0/4)	Blackice Filter	[terminated waiting to uninstall on reboot]
```

The filter's control lines (UTC−3; process and thread columns cut). Build 5's extension logged `xpc_listening ok`
both after the upgrade and after the restart; only after the restart could the CLI reach it:

```
2026-11-03 13:35:57.259 control stopped reason_1
2026-11-03 13:35:57.641 control started mode accept-all, 1 allow rule, 0 hooks, generation 26
2026-11-03 13:35:57.660 control xpc_listening ok
2026-11-03 13:36:43.679 control stopped reason_1
2026-11-03 13:37:41.914 control started mode accept-all, 1 allow rule, 0 hooks, generation 26
2026-11-03 13:37:41.934 control xpc_listening ok
```

After the restart:

```
*	*	M294LK997M	com.valentorassa.blackice.filter (0.1.0/5)	Blackice Filter	[activated enabled]
filter: enabled
configuration: mode accept-all, 1 allow rule, 0 hooks, generation 26
No connection is waiting.
No approvals.
	endpoints = {
		"M294LK997M.com.valentorassa.blackice.filter" = {
			active = 1
curl pypi.org: 200
curl api.github.com: 200
```

**Recording.** None.

**Limits.**
- **An upgrade, not a first install.** The extension was already allowed in System Settings, so the first-time
  approval of step 4 of the guide did not happen, and the zip path of steps 1 and 2 was not followed by hand
  (`package.sh` ran the same checks on the zip before it was published).
- **No uninstall.** blackice stayed installed; `blackice stop` and `brew uninstall --cask` were not run.
- **Accept-all only.** The run does not use ask mode or the daemon; P2-02 and P4-01 cover those with build 4.
- Build 5 needed the restart after an upgrade in place, as build 4 did. Why macOS leaves the upgraded extension's
  launchd job without its endpoint is not known.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 13:32:55 to 13:38 UTC−3 (16:32 to 16:38 UTC).
