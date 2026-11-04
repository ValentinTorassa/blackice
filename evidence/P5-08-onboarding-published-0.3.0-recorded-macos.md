# P5-08: The onboarding from the published 0.3.0, recorded: one `blackice start` to fx answering in 76 s (macOS)

**Claim.** One Mac was reset to no blackice, no configuration and no fx. The site's curl one-liner then installed the
published 0.3.0, and one `blackice start` reached ask mode with fx answering in 1 min 16 s:
1. The lists: the person picked ask mode, fx to answer, and no apps.
2. Touch ID, then the System Settings steps.
3. fx's own installer.
4. fx's sign-in in the browser.
5. A test on a sample connection, which fx approved in 16 s.
6. fx's rule and hook.
7. Touch ID again, ask mode and the daemon.

A screen recording covers the install and the whole `start`.

It found two problems:
- In the list of apps, the person pressed Enter on an app, which confirmed the list with nothing picked. In 0.3.1
  (e81a49c) Enter ticks the app and a Continue row confirms.
- In the next ten minutes of ask mode, a VPN client's network extension opened connections in bursts. fx could not
  keep up, since it answers in about 16 s and blackice runs at most 4 hooks at once: 62 of 94 events got no hook,
  and 31 connections were dropped at the deadline.

This bears on phase 5's question of how a person gets from nothing to an agent answering, and on phase 4's agent
keeping up with a working Mac.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. The same
user account as P5-06 and P5-07. The commands ran in Ghostty, a terminal emulator; the sign-in page opened in the
default browser. fx 0.0.16, installed during the run.

**Build.** The published 0.3.0: Blackice.app 0.3.0 (build 13, from 78730ee), signed with the Developer ID,
notarized and stapled. The install script downloaded it from the GitHub release `v0.3.0`
(`Blackice-0.3.0.zip` SHA-256 `4bc2548f7d69fed8df4a12b31dc4610dfe81a71e6673e18a000fec48425d6b86`). The Mac had build
13 before the reset, installed the same way from the same zip (P5-07).

**Configuration.** None at the start. The file at the end, as `start` wrote it:

```toml
# blackice configuration, written by blackice.
# Change it any time, then load it with: blackice start
# Every key: https://blackice-macos.vercel.app/docs/configuration

mode = "ask"            # accept-all, ask or block-all
timeout_seconds = 60    # in ask mode, no answer in time means deny

# Let an app reach some hosts in every mode. It is named by its signing identifier, and
# its Team ID unless it is Apple's own; codesign -dv shows both.
# [[allow]]
# app = "com.apple.curl"
# hosts = ["pypi.org"]

# fx answers the connections that wait in ask mode (added by blackice agent connect fx).
[[allow]]
app = "com.vercel.fx"
team = "JW6Y669B67"
hosts = ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"]

[[hook]]
on = "connection"
run = 'FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="/Users/valen/.config/blackice/agent" "/Users/valen/.local/bin/fx" ask --no-save --no-color "Use the blackice skill to decide whether to approve the pending connection"'
```

**Run.**
1. 22:26:13, off camera, a script checked that the site's install script installs 0.3.0. It ran `blackice agent
   uninstall` and `blackice stop` (Touch ID), removed the app and the command, and moved `~/.config/blackice` and
   `~/.local/bin/fx` aside.
2. 22:33:53, the person started a screen recording of the whole screen, 89 s long.
3. In a new Ghostty window: `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh`, then `blackice start`.
   The person answered the lists, Touch ID twice, System Settings, the install question and the browser page.
4. 22:35:17, `start` returned, and the prompt showed "took 1m 16s". The recording stopped a few seconds later.
5. 22:45 to 22:50, the daemon's event log since the end of `start`, and `blackice status`.

**Result.**

- **Install.** The script downloaded `Blackice-0.3.0.zip.sha256` and `Blackice-0.3.0.zip` from the `v0.3.0` release.
  It printed the SHA-256 above "as Blackice-0.3.0.zip.sha256 says", a valid signature from team M294LK997M, and
  "Gatekeeper: accepted, source=Notarized Developer ID". It wrote `~/.local/bin/blackice`.
- **The lists.** Ask mode and fx were picked with the arrows and Enter. The list of apps showed the eight apps running
  then and "Another app: type its path or name". The person moved to one app and pressed Enter, and the list closed
  with nothing ticked: "Ask mode, no rules, no hooks, 60 s to answer." In 0.3.0 only space or a digit ticked an
  app, and the hint line ("↑↓ move · space picks · Enter confirms") was not enough. In 0.3.1 (e81a49c) Enter or
  space ticks or unticks the highlighted app, and a last row, `→ Continue`, confirms.
- **Touch ID and System Settings.** The first Touch ID prompt read "Blackice is trying to start filtering in
  accept-all mode, no rules, no hooks." macOS showed its dialog that "blackice" would like to use a new network
  extension, and the person followed the printed steps. The output went on "✓ Allowed", "✓ blackice is on, in
  accept-all mode", and "It stays in accept-all while fx is set up, then switches to ask."
- **fx.** "Install fx now? [Y/n]: Y", then "installed fx 0.0.16" and "✓ ~/.local/bin/fx is com.vercel.fx, team
  JW6Y669B67". At the sign-in, fx printed its device code and Enter opened the page. The browser showed
  "Authorization Successful", and the output went on:

  ```
  Signed in to Vercel.
  AI Gateway access may still require billing or API setup for the selected account.
    ✓ fx is signed in
    ✓ There, fx may run blackice approve and blackice deny, and nothing else
  6 · Try it on a sample connection
    fx is deciding whether Visual Studio Code may reach
    update.code.visualstudio.com. blackice is a stand-in for this test, so
    nothing is let through…
    ✓ fx approved it in 16 s
  7 · Add fx to ~/.config/blackice/blackice.toml
    ✓ A rule lets fx reach its model in every mode:
      ai-gateway.vercel.sh, vercel.com and api.vercel.com
    ✓ A hook runs fx for each connection that waits
      Saved ~/.config/blackice/blackice.toml
  8 · Turn it on
  Touch ID to start filtering in ask mode, 1 rule, 1 hook, 60 s to answer…
  Activating the network extension…
  ✓ Network extension active.
  ✓ blackice is on, in ask mode.
    Connections no rule covers wait until you, or a hook, answers.
  ✓ The daemon is running, and starts again at each login.
    It runs your hooks for connections that wait.
    Its logs are in ~/Library/Logs/blackice.
  ✓ fx answers what no rule covers. See what waits with: blackice pending
  ```

  This time the account signed in had AI Gateway set up, unlike the first sign-in of P5-06.
- **Ten minutes of ask mode.** From 22:35:17 to 22:50 the daemon received 94 events:

  | Minute | Events |
  | --- | --- |
  | 22:35 | 10 |
  | 22:36 | 4 |
  | 22:37 | 29 |
  | 22:38 to 22:43 | 15 |
  | 22:44 | 35 |
  | 22:50 | 1 |

  53 of the 94 came from a VPN client's network extension, mostly in the two bursts. The rest came from a chat app,
  Apple services and other apps. The daemon started 32 hooks; the other 62 events were logged as `hook_dropped`
  with the reason `concurrency_limit`, since 4 hooks were already running. fx answered 31: 25 approvals and 6
  denials, each 9.9 to 26.6 s after its hook started, 16.1 s at the median. 31 connections were dropped at the
  deadline with no answer. At 22:50 `status` showed 32 apps and hosts waiting and 23 approvals.

**Log lines.** None copied: the run's output is in the recording, and the event counts above come from the
daemon's event log (`~/Library/Logs/blackice/events.jsonl` on the Mac), counted from 01:35:00 UTC.

**Recording.** A screen recording of the whole screen, 89 s, 2940×1912, `Screen Recording 2026-11-03 at
22.33.53.mov`, SHA-256 `f729dc20e39d4c3156f42f43e69d098b80ae06dacdb6515c20cc0773140f9e05`. Kept outside the
repository.

**Limits.**
- Because of the list, no app was trusted, so every app's new connections went to fx. The configuration guide
  advises `hosts = ["*"]` for VPN clients; with the VPN client's extension
  (`io.tailscale.ipn.macsys.network-extension`, team W5364U7YZB) trusted, most of these events would not exist.
  That was not tried. The first start's list offers running apps from `/Applications`, so a VPN client's network
  extension, which runs from `/Library/SystemExtensions` with its own signing identifier, is not offered at all.
- A burst beyond 4 events gets no hook at all: there is no queue. See "Hooks in a burst" in `docs/plan.md`.
- 0.3.1's list was tried by hand on the same Mac with a debug build (`blackice init` with a temporary file), not
  from a release.
- Same user account, so `~/.local/bin` was on `PATH` already. The Mac had not been restarted since the extension
  builds of the day.
- The times in the run come from the recording's clock and the terminal's prompt, to the second.
- One person, building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 22:26:13 to 22:50 UTC−3 (01:26 to 01:50 on 4 November UTC).
