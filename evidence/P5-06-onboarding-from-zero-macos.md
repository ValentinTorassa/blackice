# P5-06: From no blackice and no fx to fx answering in ask mode, with 0.3.0 candidates (macOS)

**Claim.** On one Mac, with blackice, its configuration and fx removed first, candidate build 11 of 0.3.0 got from
the curl one-liner to fx approving real connections in ask mode:
1. The install one-liner checked the candidate's zip and installed the app into `/Applications`.
2. The first `blackice start` asked its questions as lists. The person picked ask mode, fx to answer, and no apps.
3. After Touch ID and the System Settings steps, `start` turned blackice on in accept-all, ran fx's own installer,
   gave fx its home and signed it in through the browser.
4. fx's test failed with HTTP 403: the Vercel team picked at sign-in had no card on file for AI Gateway. `start`
   exited 70 and left `blackice.toml` as it was.
5. With fx's sign-in from 2 November put back, `blackice agent connect fx` tested fx (approved in 9 s), added its
   rule and hook, and loaded ask mode with one Touch ID.

fx then approved two `nscurl` requests 5 s after they started, and both got their responses.

Builds 9 and 10 of the same candidate failed on the way: an fx installer that waited in ask mode, a sign-in cut
when the filter started, and a sign-in that froze at its Enter prompt. Each failure has its fix in build 11. The
403's message came after build 11 (see Result).

This bears on phase 5's question of how a person gets from nothing to an agent answering.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. The same
user account as P5-04 and P5-05, so `~/.local/bin` was already on `PATH`. fx 0.0.16, installed during the runs by
fx's installer (`curl -fsSL https://fx.sh/setup.sh | bash`) at `~/.local/bin/fx`, signed `com.vercel.fx`, team
JW6Y669B67. The model was fx's default and was not recorded.

**Build.** Three candidates of 0.3.0, not published. Each was signed with the Developer ID, notarized and stapled:

| Build | Commit | `Blackice-0.3.0.zip` SHA-256 |
| --- | --- | --- |
| 9 | fc26c4c | `968ec72906f6baf288657b662b72566a16b0106801f2e8d24c78a42872b1e51d` |
| 10 | 0611806 | `6f75232fd74130a8119a96b5a20d9a878e7b67ac9a9b0086d8b935130cbcae66` |
| 11 | 2474adc | `16206125d026f1c74bcb30408a2f678a69dd6e21cf7ce4beff4367efb093b59b` |

The install script was the candidate's, from a preview deployment of the site. `BLACKICE_ZIP` pointed it at the
zip on the Mac, and the script read the checksum from the `.sha256` file next to it. Before the first run the Mac
had build 8 from P5-05.

**Configuration.** None at the start: `~/.config/blackice` was moved aside. Build 11's first `start` wrote ask mode,
`timeout_seconds = 60`, no rules and no hooks. `agent connect fx` added the rest. The file at the end:

```toml
# blackice configuration, written by blackice init.
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

The first line says `init` although `start` wrote the file. It now says "written by blackice".

**Run.** Each run was a script opened in a Terminal window on the Mac, with the person at the Mac for Touch ID,
System Settings, the lists, the questions and the browser. `start` and `agent connect` ran under `script`, which
gave each a terminal. Each run began where the last one stopped:
1. 20:26:02, uninstall following the install guide (`blackice agent uninstall`, `blackice stop` with Touch ID,
   remove the app and the command). `~/.config/blackice` and `~/.local/bin/fx` were moved aside.
2. 20:28:10, build 9: the one-liner, `blackice start`, then at 20:36:49 `blackice agent connect fx`.
3. 20:56:33, build 10: uninstall again, the one-liner, `blackice start`. At 20:59:33, `blackice agent connect fx`.
4. 21:15:32, build 11: uninstall again (with the configuration and fx moved aside again), the one-liner,
   `blackice start`.
5. Between 21:16:48 and 21:17:59, the person chose to use fx's sign-in from 2 November. The new sign-in was moved
   aside, and the earlier one was copied into `~/.config/blackice/agent`.
6. 21:17:59, `blackice agent connect fx`, then `status`.
7. 21:18:32, `nscurl` to `https://api.github.com/zen` and to `https://pypi.org/simple/` at once, `blackice pending`
   3 s later, and the event log's verdicts.
8. 21:18:41, the person kept ask mode on. `status` at 21:18:53.

Two more runs, at 20:52:47 and 21:10:56, stopped at their first step: nobody touched the sensor within about
2 minutes, so `blackice stop` printed "Touch ID was cancelled, so nothing changed." and exited 77. The script put
the daemon back and changed nothing else.

**Result.**

- **Install, each build.** The one-liner printed the zip's SHA-256 as the `.sha256` file gave it, a valid signature
  from team M294LK997M, and "Gatekeeper: accepted, source=Notarized Developer ID". It installed the app and wrote
  `~/.local/bin/blackice`. `blackice version` then printed the expected build.
- **Build 9: fx's installer waited in ask mode.** Build 9's `start` asked typed questions. The person answered ask
  mode, 60 s and no apps, and `start` turned on ask mode with no hook. `agent connect fx` then offered fx's
  installer, and its download waited like every other new connection, with nobody to answer:

  ```
  curl: (7) Failed to connect to fx.sh port 443 after 68083 ms: Couldn't connect to server
    fx's installer exited with status 0, and fx is still not
    on PATH or in ~/.local/bin. Install it (https://github.com/vercel-labs/fx), then run this again.
  ```

  The pipe hid curl's status, hence "status 0". A second try was stopped at its question, to move on to build 10.
  The changes, in build 10 (19cb678):
  - `start` asks with lists.
  - Picking ask mode and fx makes `start` turn blackice on in accept-all, set fx up, and load ask mode at the end.
  - `agent connect` switches to accept-all first when ask or block-all is running.
  - fx's installer runs with `pipefail`.
- **Build 10: the filter cut fx's sign-in.** The lists, Touch ID, System Settings and fx's installer worked
  ("installed fx 0.0.16"). Then fx's sign-in printed "fx login: failed to sign in", and `start` exited 70 at
  20:57:54. `start` had gone on before the extension answered. The filter came up about 20 s after the
  configuration was saved, during the sign-in, and macOS closed the connections open at that moment. The changes,
  in build 11 (90e4b81):
  - After saving the configuration, `start` waits up to 20 s for the extension to answer.
  - A failed sign-in is offered again ("fx is not signed in yet. Try again? [Y/n]").
- **Build 10: the sign-in froze.** The second try, `agent connect fx`, ran fx's sign-in. fx printed its device code
  and "press enter to open this in your browser". The person pressed Enter, nothing happened, and they closed the
  window. Foundation's `Process` started fx in a process group of its own. The terminal treated that group as
  background, so fx stopped at its first read from the terminal (SIGTTIN). In build 11 (2474adc), blackice starts
  fx with `posix_spawn`, which keeps it in blackice's process group, and the hint says to press Enter.
- **Build 11, `start`.** The output as it looked when the person pressed Enter on each list (blank lines left out;
  the apps list is summarized; the device code is replaced):

  ```
  Setting up blackice: pick a mode, confirm with Touch ID, then allow its
  network extension if macOS asks.
  1 · Pick a mode
    How should blackice treat new connections?
        accept-all   Let everything through and log it
      ❯ ask          Hold what no rule allows until fx or you answer
        block-all    Let through only what your rules allow
    Who answers the connections that wait?
      ❯ fx, a coding agent: blackice installs it if needed and sets it up
        Me, with blackice pending, approve and deny
    Apps you trust connect to any host, in every mode, without waiting.
    Pick them from the apps running now, or press Enter for none.
      [the apps running then and "Another app: type its path or name", none ticked]
    ✓ Saved ~/.config/blackice/blackice.toml
      Ask mode, no rules, no hooks, 60 s to answer. Edit it any time.
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
    It stays in accept-all while fx is set up, then switches to ask.
  4 · Find fx
    fx is not installed. Its installer, from https://github.com/vercel-labs/fx:
      curl -fsSL https://fx.sh/setup.sh | bash
    Install fx now? [Y/n]: y
  installed fx 0.0.16
  /Users/valen/.local/bin/fx
    ✓ ~/.local/bin/fx is com.vercel.fx, team JW6Y669B67
  5 · Give fx a home of its own
    ✓ The blackice skill is in ~/.config/blackice/agent
    Sign fx in for blackice.
    fx prints a code. Press Enter to open the page in your browser, allow
    access there, then come back here.
  Open https://vercel.com/oauth/device?user_code=[code]
  Code: [code]
  Waiting for authentication. press enter to open this in your browser, or use the URL manually.
  Signed in to Vercel.
  AI Gateway access may still require billing or API setup for the selected account.
    ✓ fx is signed in
    ✓ There, fx may run blackice approve and blackice deny, and nothing else
  6 · Try it on a sample connection
    fx is deciding whether Visual Studio Code may reach
    update.code.visualstudio.com. blackice is a stand-in for this test, so
    nothing is let through…
    fx exited with status 1 and gave no answer, so blackice.toml was left as it was.
    fx's last lines:
      fx ask: API access denied · HTTP 403 · customer_verification_required: AI Gateway requires a valid credit card on file to service requests. Please visit https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fa
    If blackice is in ask or block-all mode, fx's own connections wait too: switch to
    accept-all (blackice mode accept-all), then: blackice agent connect fx
  ```

  It exited 70 at 21:16:48, 63 s after `start` began. The last hint was wrong here: blackice was in accept-all. In
  88f4f32, after build 11, an fx test that fails with `customer_verification_required` prints "Vercel's AI Gateway
  needs a card on file for the team fx signed in with. Add one in that team's billing settings on vercel.com, then
  run this again." instead.
- **Build 11, `agent connect fx`.** The output, as printed (blank lines left out):

  ```
  Connecting fx to blackice: it will answer the connections that wait in
  ask mode, with nobody at the keyboard.
  1 · Find fx
    ✓ ~/.local/bin/fx is com.vercel.fx, team JW6Y669B67
  2 · Give fx a home of its own
    ✓ The blackice skill is in ~/.config/blackice/agent
    ✓ fx is signed in there
    ✓ There, fx may run blackice approve and blackice deny, and nothing else
  3 · Try it on a sample connection
    fx is deciding whether Visual Studio Code may reach
    update.code.visualstudio.com. blackice is a stand-in for this test, so
    nothing is let through…
    ✓ fx approved it in 9 s
  4 · Add fx to ~/.config/blackice/blackice.toml
    ✓ A rule lets fx reach its model in every mode:
      ai-gateway.vercel.sh, vercel.com and api.vercel.com
    ✓ A hook runs fx for each connection that waits
      Saved ~/.config/blackice/blackice.toml
  5 · Turn it on
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

  It exited 0, and the next stage began at 21:18:32. Step 5 did not ask whether to switch to ask mode, since
  `start` had already written ask mode in the file. `status` showed ask mode, 1 rule, 1 hook run by the daemon, and
  60 s to answer.
- **Real connections.** `pending` listed both events 3 s after the requests started, each with 58 s left:
  `apple/com.apple.nscurl` to api.github.com holding 1 connection, and to pypi.org holding 8. fx approved each for
  10 minutes, about 5.2 s after its event arrived. `nscurl` printed pypi.org's index after 5 s and api.github.com's
  "Design for failure." after 6 s.

  | Verdict at | App | Host | fx | Hook time |
  | --- | --- | --- | --- | --- |
  | 21:18:37.761 | `com.apple.nscurl` | pypi.org | approved | 8.1 s |
  | 21:18:37.861 | `com.apple.nscurl` | api.github.com | approved | 7.3 s |

  The hook time runs from the hook's start to fx's exit, 2 to 3 s after its verdict. At 21:18:53 `status`
  counted 2 approvals and nothing waiting.

**Log lines.** The daemon's event log for the two `nscurl` events, with `stderr` left out:

```
{"app_path":"/usr/bin/nscurl","app_signing_id":"com.apple.nscurl","deadline":"2026-11-04T00:19:32Z","event":"ev-a6806c30","host":"api.github.com","ip":"4.228.31.149","port":443,"ts":"2026-11-04T00:18:32.610Z","type":"event_received"}
{"event":"ev-a6806c30","hook_line":20,"pid":41871,"ts":"2026-11-04T00:18:32.611Z","type":"hook_started"}
{"app_path":"/usr/bin/nscurl","app_signing_id":"com.apple.nscurl","deadline":"2026-11-04T00:19:32Z","event":"ev-6b3798dc","host":"pypi.org","ip":"2a04:4e42:600::223","port":443,"ts":"2026-11-04T00:18:32.611Z","type":"event_received"}
{"event":"ev-6b3798dc","hook_line":20,"pid":41872,"ts":"2026-11-04T00:18:32.612Z","type":"hook_started"}
{"event":"ev-6b3798dc","ts":"2026-11-04T00:18:37.761Z","type":"verdict","verdict":"approved"}
{"event":"ev-a6806c30","ts":"2026-11-04T00:18:37.861Z","type":"verdict","verdict":"approved"}
{"duration_ms":7344,"event":"ev-a6806c30","hook_line":20,"status":0,"ts":"2026-11-04T00:18:39.955Z","type":"hook_exited"}
{"duration_ms":8107,"event":"ev-6b3798dc","hook_line":20,"status":0,"ts":"2026-11-04T00:18:40.720Z","type":"hook_exited"}
```

Each left-out `stderr` ends with the command fx ran and blackice's reply. pypi.org's, with the token as the hook
runner wrote it:

```
Running blackice approve --app 'com.apple.nscurl' --host 'pypi.org' --for 10m --token [token]
approved apple/com.apple.nscurl -> pypi.org for 600 s; 8 waiting connections, 8 allowed
```

**Recording.** None.

**Limits.**
- The builds are candidates. Two changes came after build 11 and have unit tests only: the AI Gateway card message
  (88f4f32) and the file's first line.
- The path did not run in one go. The new sign-in went to a team without a card, so `start` stopped at the test, and
  the run went on with an earlier sign-in and `agent connect fx`. A first `start` that signs fx in to a team with a
  card and goes on to load ask mode by itself has not run. Nor has the sign-in offered again after a failure.
- Same user account: `~/.local/bin` was on `PATH` already. The Mac was not restarted between builds, so earlier
  versions of the extension were still listed as waiting to uninstall on reboot.
- The lists ran in Terminal.app only. With `TERM=dumb` or no terminal, `start` falls back to typed questions;
  only unit tests cover that.
- The person picked no apps from the list, and picked fx, not "Me". The other answers ran only in `WizardTests`.
- The 20 s wait for the extension let the sign-in through once. How long the filter takes to come up was not
  measured beyond build 10's run.
- Build 11 dropped Apple's developer tools and Mac App Store apps as `invalid_signature` in ask mode, without
  asking (P5-07). `nscurl` and fx were not affected, so this run did not show it.
- fx approved `nscurl` here and denied it in P5-05. Which connections an agent approves depends on the model and
  varies between runs.
- When the filter started, macOS closed the SSH sessions that followed the logs, as in P5-04.
- The runs' logs, outside the repository: `~/blackice-p5/onboard-20261103-*.log` on the Mac.
- One person, building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 20:26:02 to 21:18:53 UTC−3 (23:26 on 3 November to 00:18 on 4 November UTC).
