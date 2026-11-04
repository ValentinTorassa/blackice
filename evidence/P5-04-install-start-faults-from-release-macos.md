# P5-04: uninstall, the install script into /Applications, the first start's steps, and the fault tests, from the published 0.2.1 (macOS)

**Claim.** On one Mac, from the published v0.2.1 release, the uninstall steps of `docs/install.md` removed the
previous install. The curl one-liner then installed Blackice.app 0.2.1 into `/Applications` after checking its
checksum, signature and notarization.

The first `blackice start`, with no `blackice.toml`, went through its three numbered steps:
1. It wrote the file from the defaults.
2. It asked for Touch ID.
3. It opened System Settings and listed what to click. The extension was allowed and blackice was on in accept-all
   mode 19 s after `start` began.

`blackice agent install` started the daemon. The fault tests passed all 28 of their checks. Loading the original
configuration again took one more Touch ID.

This bears on phase 5's checks: an install from the published package, uninstalling, and the fault tests on a
released build.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled.

**Build.** Blackice.app 0.2.1 (build 7) from the v0.2.1 release (`Blackice-0.2.1.zip`, SHA-256
`da8bd749bc0abdddee6afa98f93940d84903024a32545529bc6685bd0b07e909`), built from commit 004bf9b. The install
script is the one production served at `https://blackice-macos.vercel.app/install.sh` on 3 November 2026 at 18:30
(`VERSION=0.2.1`). Before the run, 0.2.0 (build 6) was in `/Applications`, installed by the same script for an
earlier attempt (below). Its extension was `activated waiting for user`, and 0.1.0's was waiting to uninstall at
the next restart.

**Configuration.** The person's own `~/.config/blackice/blackice.toml` was moved aside before the start, so that the
first start found none. It went back at the end: accept-all mode, one rule (`com.apple.curl` to `pypi.org`), no
hooks. The fault tests use their own file (`fault.toml`: ask mode, 1 rule, 1 hook, 30 s to answer).

**Run.** A script launched in a Terminal window on the Mac, with the person at the Mac for Touch ID and System
Settings. `blackice start` ran under `expect`, which gave it a terminal and pressed Enter at the mode question.
1. 18:26, uninstall, following `docs/install.md`:
   - `blackice agent uninstall`: not loaded.
   - `blackice stop`, with Touch ID 1: "Network extension removed".
   - `rm -rf /Applications/Blackice.app` and `rm ~/.local/bin/blackice`.

   Afterwards `systemextensionsctl list` showed only 0.1.0, waiting for the restart. pypi.org and api.github.com
   answered HTTP 200.
2. 18:30:04, `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh`.
3. 18:30:08, `blackice start` with no `blackice.toml`. Then `blackice status`, `blackice agent install` and
   `blackice pending`.
4. 18:30:31, `macos/scripts/fault-test.sh` (Touch ID 3 and 4).
5. 18:32:43, the original `blackice.toml` back, then `blackice start` (Touch ID 5).

**Result.**

- **Install.** The script downloaded the checksum and the zip from the v0.2.1 release and matched the SHA-256. It
  reported the signature as valid, from a Developer ID Application certificate of team M294LK997M, and Gatekeeper
  as `accepted, source=Notarized Developer ID`. It copied the app and wrote `~/.local/bin/blackice`. `codesign
  --verify --strict --deep`, `stapler validate` and `spctl --assess` passed on the installed app, and a login
  shell found the command.
- **First start.** The output, as printed (lines 1-11 of the wizard elided):

  ```
  Setting up blackice: pick a mode, confirm with Touch ID, then allow its
  network extension if macOS asks.

  1 · Pick a mode
    …
    ✓ Saved ~/.config/blackice/blackice.toml
      Accept-all mode, no rules, no hooks. Edit it any time.

  2 · Confirm with Touch ID

    Touch the sensor, or type your password, when macOS asks.
    ✓ Confirmed

  3 · Allow the network extension

    System Settings is open at General › Login Items. There:

      1. Scroll to Blackice in the list and click ⓘ next to it.
      2. Turn on Network Extension, then click Done.

    Waiting for you (up to 10 minutes)…
    ✓ Allowed
    macOS now asks whether Blackice may filter network content: click Allow.

  ✓ blackice is on, in accept-all mode.
    Every connection goes through and is logged.
  ```

  The filter logged `control started mode accept-all, 0 allow rules, 0 hooks, generation 1` at 18:30:27.706.
  `systemextensionsctl list` showed `com.valentorassa.blackice.filter (0.2.1/7) [activated enabled]`.
- **Daemon.** `agent install` loaded the LaunchAgent, `pending` answered "No connection is waiting", and pypi.org
  and api.github.com answered HTTP 200.
- **Fault tests.** All 28 checks passed, and the script exited 0:
  - **Case 1, no daemon.** A connection waited in the pending list and was dropped at the 30 s deadline. nscurl
    failed after 32 s.
  - **Case 2, a hung hook.** The hook was killed at the deadline (`hook_killed:deadline` after 29088 ms), the
    connection was dropped 30.7 s after its event, and the hook's child process was gone.
  - **Case 3, a burst.** 70 connections to one host shared one event, which held 64; the rest were dropped as
    `ask_capacity`. 50 distinct hosts raised 50 events. At most 4 hooks ran at once, and 46 were logged as
    dropped (`concurrency_limit`). During the burst curl reached pypi.org at once, `blackice status` answered,
    and the extension stayed enabled.
  - **Case 4, restarts and a change.** launchd restarted a killed daemon, which registered again within 1 s and
    ran the hook for both waiting events. Switching to accept-all while they waited dropped their 28 paused
    connections (`configuration_changed`) and cancelled both events.

  P5-01's failures did not come back. The second Touch ID was given, and `pending` read a reply with an event that
  had no connections left.
- **End state.** Blackice.app 0.2.1 build 7, its extension activated and enabled, the daemon loaded, and `status`
  showing accept-all with 1 rule and no hooks.

**The earlier attempt, 0.2.0 (17:44 to 18:04).** The same session with 0.2.0 removed the Homebrew install of 0.1.0:
- `blackice stop` worked.
- `brew uninstall --cask blackice` took 8 min 46 s, between "Removing App" and "Purging files". It most likely
  waited on macOS's App Management prompt for Terminal, which `docs/install.md` mentions. The log does not show it.

The curl one-liner then installed 0.2.0 into `/Applications`, and `start` ran the wizard. It printed the System
Settings step as one paragraph naming General › Login Items & Extensions › Network Extensions, macOS 15's place.
On macOS 27 the pane is General › Login Items, a list of apps, and it opened scrolled to the end, past Blackice.
Nobody found the switch within 10 minutes. `start` gave up with exit 70, leaving the extension `activated waiting
for user`. 0.2.1's numbered steps came from this.

**Log lines.** The install script's output (`~` for the home directory):

```
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.2.1/Blackice-0.2.1.zip.sha256
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.2.1/Blackice-0.2.1.zip
  SHA-256: da8bd749bc0abdddee6afa98f93940d84903024a32545529bc6685bd0b07e909, as Blackice-0.2.1.zip.sha256 says
Checking Blackice.app
  signature: valid, and satisfies its Designated Requirement
  signed by: Developer ID Application, team M294LK997M
  Gatekeeper: accepted, source=Notarized Developer ID
Blackice.app 0.2.1 is in /Applications.
Wrote ~/.local/bin/blackice, which runs /Applications/Blackice.app/Contents/MacOS/blackice.
~/.local/bin is not on your PATH. Add it, for example in ~/.zshrc:
  export PATH="~/.local/bin:$PATH"
Next:
  1. Run `blackice start`. The first time, it asks a few questions to write
     ~/.config/blackice/blackice.toml, then opens System Settings so you can allow the extension.
  2. `blackice agent install` starts the daemon that runs your hooks in ask mode.
Before removing the app, run `blackice agent uninstall` and `blackice stop`.
Install guide: https://blackice-macos.vercel.app/docs/install
```

The filter's unified log after the first start:

```
2026-11-03 18:30:27.706 Df com.valentorassa.blackice.filter[21482:3497e] [com.valentorassa.blackice.filter:control] control started mode accept-all, 0 allow rules, 0 hooks, generation 1
2026-11-03 18:30:27.722 Df com.valentorassa.blackice.filter[21482:3497e] [com.valentorassa.blackice.filter:control] control xpc_listening ok
```

The fault tests' result, verbatim:

```
PASS  1. the connection to example.com waited in the pending list
PASS  1. the filter logged 'control event_not_sent no_daemon' (6)
PASS  1. no event reached the event log
PASS  1. the filter logged 'flow drop timeout' at the deadline, 30 s in
PASS  1. nscurl got no response and waited at least the timeout (failed after 32 s)
PASS  the daemon registered with the filter ('control xpc daemon_registered')
PASS  2. the daemon received the event (ev-7d09c943) and the hook took the hung case
PASS  2. the hook was killed at the deadline (hook_killed:deadline after 29088 ms)
PASS  2. the connection was dropped at the deadline (verdict timed_out, 30.7 s after the event)
PASS  2. the hook's sleep is gone (pid 21694)
PASS  2. nscurl got no response (failed after 32 s)
PASS  3. the 70 connections to example.org shared one event (1)
PASS  3. that event held 64 connections, at most 64
PASS  3. connections over 64 per event were dropped ('flow drop ask_capacity': 496)
PASS  3. 50 of 50 distinct hosts raised an event (50 events)
PASS  3. at most 4 hooks ran at once (most seen in the event log: 4)
PASS  3. hooks over the limit were logged as dropped (4 started, 46 dropped: concurrency_limit)
PASS  3. every burst event ran its hook or was logged as dropped (0 with no record, 0 dropped otherwise, 0 failed)
PASS  3. curl reached pypi.org during the burst (HTTP 200 after 0 s)
PASS  3. blackice status answered during the burst
PASS  3. the extension is still activated and enabled
PASS  4. launchd started the daemon again (pid 21679, then 22191)
PASS  4. the new daemon registered with the filter ('control xpc daemon_registered', seen within 1 s)
PASS  4. the new daemon received both events and ran the hook (2 of 2)
PASS  4. both connections were waiting before the change (2 of 2 in the pending list; change 19 s in)
PASS  4. the filter installed the change ('control configuration_installed mode accept-all')
PASS  4. paused connections were dropped ('flow drop configuration_changed': 28)
PASS  4. their events were cancelled (2 of 2: www.example.com:cancelled www.example.net:cancelled)
```

**Recording.** None.

**Limits.**
- One Mac, one macOS version, and one run per check. The macOS 14 and 15 steps that 0.2.1 prints have not been run.
- Whether macOS asked "filter network content" after the extension was allowed was not recorded. The filter was
  saved within a second of "✓ Allowed", which suggests it did not ask.
- When the filter started, at 18:30:27, macOS closed the SSH session that was following the log ("closed by remote
  host"). It happened again in P5-05. Starting a content filter may close connections that are already open.
- `blackice start` ran under `expect`, which pressed Enter for the default mode. A person types it.
- The run's log, outside the repository: `~/blackice-p5/run2-20261103-183004.log` on the Mac, with the uninstall in
  `run2-20261103-182615.log` and the earlier attempt in `run-20261103-174437.log`.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 18:26:15 to 18:32:45 UTC−3 (21:26 to 21:33 UTC); the earlier attempt 17:44 to 18:04 UTC−3.
