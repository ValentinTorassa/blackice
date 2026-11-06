# P5-15: the 1.0.0 candidates through an upgrade, the fault tests and a first start from zero

**Claim.** Two 1.0.0 candidates, signed and notarized, passed the three runs set before 1.0.0 could ship. Build 29
upgraded the published 0.4.7 in place in ask mode, with no restart: the new extension started 0.32 s after the old one
stopped. It passed all 29 fault checks, and from no blackice at all one `blackice start` reached accept-all in 24 s.
After its first start in ask mode, the code showed that a picked app's rule left out the app's helpers, so build 30
fixes that, ticks the common apps and lists Codex and opencode only once connected. Build 30 then upgraded build 29 in place, and its first
start in ask mode wrote 27 rules for the six picked apps and their helpers, reaching ask mode with Claude Code
answering 31 s after the Terminal opened. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi. From the
fault tests on, the Wi-Fi's DNS server was 8.8.8.8 and Tailscale's DNS was off (see the fault tests below).

**Builds.** Blackice.app 1.0.0, signed with the Developer ID Application of team M294LK997M, notarized and stapled:

- build 29, from 2142cca, `Blackice-1.0.0.zip` SHA-256 `4be3a3d35878f550050f829c13d40aeb3e695793b87088dedd071898d3e4647c`;
- build 30, from b37de79, SHA-256 `911b5fab9dd2f8e7f41a996a4dd041e3df28cf7c646fb47780802d7c7fec11d1`, the build
  released as 1.0.0. Since build 29 it changes only the first start's lists (`Wizard.swift`, `CLI.swift`,
  `AgentInstructions.swift`) and `package.sh`; the filter and the daemon are the same code.

Each was installed with the site's install script and `BLACKICE_ZIP` pointing at the zip, which runs the checks of a
published install (checksum, signature and team, notarization, version).

**Run.** 6 November 2026, from a Claude Code session on the Mac, with the owner at the Mac for Touch ID and the first
start's lists. Times are the Mac's (UTC−3).

1. 13:56, upgrade in place: the owner's configuration (21 rules, ask, Claude Code answering) on the published 0.4.7,
   build 28. The script with `--force`, then `blackice start`.
2. 14:06 and 14:10, `macos/scripts/fault-test.sh` on build 29, then `blackice start` of the owner's file.
3. 14:13, from zero on build 29: `blackice menu --login off`, `blackice agent uninstall`, `blackice stop` (Touch ID,
   which removed the extension), the owner's configuration set aside and the app and command deleted. The script,
   then `blackice start` in a new Terminal window, first picking accept-all, then again with that file set aside,
   picking ask and Claude Code.
4. 14:48, upgrade in place from build 29 to build 30, with the test file of step 3 (4 rules), in accept-all.
5. 14:49, from zero on build 30: that file set aside and the app and command deleted, with the extension left
   active. The script, then `blackice start` in a new Terminal window: ask, Claude Code, and the list as it came.
6. The owner's configuration back, with `blackice start`.

**Result.**

1. The upgrade: the filter's log shows build 28 stopping at 13:57:01.763 and build 29 starting at 13:57:02.080 with
   the saved configuration (21 rules, 1 hook); `start` then tested Claude Code and turned on ask mode at 13:57:14.
   `systemextensionsctl list`: `1.0.0/29 [activated enabled]`. No restart.
2. The fault tests: the first run failed 7 of 29 checks, all of them the cases that connect to `example.com` and
   `www.example.com`, which the Wi-Fi router (192.168.1.1) did not resolve while 8.8.8.8 did. With 8.8.8.8 as the
   Wi-Fi's DNS server the second run passed 29 of 29: daemon down, hook hung, the burst (at most 4 hooks at once, 46
   waiting for a slot, `curl` to pypi.org answered during it) and the restart with the change to accept-all. The
   owner's file then started in ask mode, though the test file had been switched to accept-all: the fix in 0.4.7 holds.
3. From zero on build 29: the script took 0.47 s. The first `start`, in accept-all, took 24 s with the extension's
   Allow and the menu at login. In ask mode the list started with the three network extensions, ticked (Tailscale's,
   Proton VPN's WireGuard tunnel and its split tunneling), and Claude Code was tested before ask mode. The file had 4
   rules: the three extensions and Claude Code's. No app was picked in that run; reading the code after it showed that a
   picked app got one rule, for its own signing identifier, while a browser's connections come from its helper
   (`com.google.Chrome.helper`), so they would still have waited. Build 30 writes the helpers' rules too, and lists
   the split tunneling unticked.
4. The upgrade to build 30: `1.0.0/30 [activated enabled]`, the 4 rules kept, no restart.
5. From zero on build 30: the script took 0.61 s. Ticked at the top of the list: Proton VPN's WireGuard tunnel,
   Tailscale's extension, and the common apps running (Brave, Firefox, Chrome, WhatsApp). Unticked below: Proton
   VPN's split tunneling, which is a proxy for other apps' connections, and the other apps running (Bitwarden,
   Ghostty, Clipy and others). The file it wrote has 27 `[[allow]]` rules with `hosts = ["*"]` but Claude Code's: the
   two tunnels, then each app and the nested bundles signed by its team (Brave 6, Firefox 6, Chrome 5, WhatsApp 7,
   among them `com.google.Chrome.helper` and `com.brave.Browser.helper`), and Claude Code's rule to its API. The
   configuration was loaded at 14:49:43.9, 31 s after the window opened, and Claude Code answered the first two events
   in 4.2 s and 4.1 s.
6. The owner's file: ask mode, Claude Code answering, 21 rules, nothing waiting.

Decided by: the extension and the daemon (the upgrades and the fault tests), Claude Code (the events after each first
start), the owner (the picks in the lists).

**Limits.**

- One Mac, with macOS 27.0.1. macOS 14 and 15 are not tested.
- The fault tests ran on build 29, not on build 30, which changes none of the code they exercise.
- Build 30's first start ran with the extension already active from step 4, so its Allow in System Settings was not
  asked again; build 29's first start, after `blackice stop`, had it.
- A picked app's rule covers every nested bundle its team signed, its updaters among them (`com.google.GoogleUpdater`,
  Sparkle's in Brave and WhatsApp), each with `*`.

**Date.** 6 November 2026.
