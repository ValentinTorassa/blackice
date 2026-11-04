# P5-05: `blackice agent connect fx` sets fx up, tests it, turns ask mode on, and fx decides real connections (macOS)

**Claim.** On one Mac, `blackice agent connect fx` set fx up to answer the connections that wait in ask mode:
1. It found fx and read its signature.
2. It put the blackice skill and fx's rules in fx's own home.
3. fx decided a sample event through the hook runner, with `blackice` replaced by a stand-in. fx approved it in
   21 s.
4. It added fx's rule and hook to `blackice.toml` and raised `timeout_seconds`.
5. On a "y" it switched to ask mode with one Touch ID and started the daemon.

In ask mode fx then answered real connections of that Mac, each with its event's token. It denied two `nscurl`
requests, to api.github.com and pypi.org, 21 s after they started. Over the next eight minutes it decided seven
connections of other apps, approving six and denying one, in 12 to 20 s each. The first try failed at step 2, on a
folder made by hand the day before. That is fixed in code (see Result).

This bears on phase 4's agent deciding with nobody at the keyboard, and on phase 5's question of how a person gets
there.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. fx 0.0.16
at `~/.local/bin/fx`, signed `com.vercel.fx`, team JW6Y669B67, already signed in to Vercel's AI Gateway in
`~/.config/blackice/agent` (set up by hand on 2 November). The model was fx's default and was not recorded.

**Build.** A trial build, not a release: Blackice.app 0.2.1 (build 8) from commit 74d827c (branch `agent-connect`),
signed with the Developer ID, notarized and stapled (`Blackice-0.2.1.zip` SHA-256
`d20a8668c1eb407a1e3f561c8f0826509223743c3cc41c8145ee601794a53db4`, not published). It replaced the published
build 7 after `blackice stop`, so the extension was activated fresh and allowed in System Settings again.

**Configuration.** The person's `~/.config/blackice/blackice.toml` before the command: accept-all, `timeout_seconds
= 60`, one rule (`com.apple.curl` to `pypi.org`), no hooks. After it:

```toml
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 63    # in ask mode, no answer in time means deny

# Permanent rules: one app, by signing identifier (and Team ID unless it is Apple's), and its hosts.
[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

# fx answers the connections that wait in ask mode (added by blackice agent connect fx).
[[allow]]
app = "com.vercel.fx"
team = "JW6Y669B67"
hosts = ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"]

[[hook]]
on = "connection"
run = 'FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin" HOME="/Users/valen/.config/blackice/agent" "/Users/valen/.local/bin/fx" ask --no-save --no-color "Use the blackice skill to decide whether to approve the pending connection"'
```

**Run.** A script launched in a Terminal window on the Mac, with the person at the Mac. `start` and `agent connect`
ran under `script`, which gave each a terminal; the person answered their questions.
1. 18:53:18, `blackice stop` (Touch ID 1). Build 8 copied into `/Applications` in place of build 7.
2. 18:53:23, `blackice start` with the file above (Touch ID 2). System Settings opened at General › Login Items,
   and the person followed the printed steps.
3. 18:53:37, `blackice agent connect fx`. It stopped at step 2 (below). The two folders were fixed by hand and the
   command ran again at 18:54:31 (Touch ID 3).
4. 18:55:35, `nscurl` to `https://api.github.com/zen` and to `https://pypi.org/simple/` at once, then
   `blackice pending`.
5. The person kept ask mode on. `status` was read at 19:03:23 and the event log at 19:04.

**Result.**

- **Step 2, first try.** It printed "Cannot set up ~/.config/blackice/agent: The operation couldn’t be completed.
  (BlackiceCore.FileSafetyError error 1.)" and exited 73, before changing anything else. The cause:
  `~/.config/blackice/agent/.fx/skills` had mode 0755. It was made by hand on 2 November, when the agent home was
  set up following `integrations/fx/README.md`. The command refuses an agent folder that others can read.

  After the run the code was changed:
  - A folder of the agent home that is the person's own directory, not a symlink, is set to 0700.
  - Errors say their cause.
  - `AgentConnectTests` covers both, and a symlinked home is still refused.

  For this run the folders were set to 0700 by hand.
- **`agent connect fx`, second try.** The output, as printed (blank lines left out):

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
    ✓ fx approved it in 21 s
  4 · Add fx to ~/.config/blackice/blackice.toml
    ✓ fx may reach ai-gateway.vercel.sh, vercel.com and api.vercel.com in every mode
    ✓ A hook runs fx for each connection that waits
    ✓ timeout_seconds is now 63, so fx has time to answer
      Saved ~/.config/blackice/blackice.toml
  5 · Turn it on
    In ask mode, a connection no rule covers waits until fx answers (21 s on
    the test); with no answer in time it is denied.
    Switch to ask mode now? [y/N]: y
      Saved ~/.config/blackice/blackice.toml
  Touch ID to start filtering in ask mode, 2 rules, 1 hook, 63 s to answer…
  Activating the network extension…
  ✓ Network extension active.
  ✓ blackice is on, in ask mode.
    Connections no rule covers wait until you, or a hook, answers.
  ✓ The daemon is running, and starts again at each login. It runs your hooks for connections that wait.
    Its logs are in ~/Library/Logs/blackice.
  ✓ fx answers what no rule covers. See what waits with: blackice pending
  ```

  It exited 0. `status` showed ask mode, 2 rules, 1 hook run by the daemon, and 63 s to answer. At 19:10
  `~/.config/blackice/agent/test`, where the stand-in ran, was gone.
- **Real connections.** Three seconds after the two requests started, `pending` listed both events, each with
  61 s left: `com.apple.nscurl` to pypi.org holding 8 connections, and to api.github.com holding 1. Both requests
  failed after 21 s with "The network connection was lost", when the denials dropped them. The event log's
  verdicts:

  | Verdict at | App (as the event named it) | Host | fx | Hook time |
  | --- | --- | --- | --- | --- |
  | 18:55:50 | `com.apple.geod` (Apple's location services) | gsp57-ssl-background.ls.apple.com | approved | 13.0 s |
  | 18:55:56 | `com.apple.nscurl` | pypi.org | denied | 23.7 s |
  | 18:55:56 | `com.apple.nscurl` | api.github.com | denied | 23.1 s |
  | 18:56:20 | the Codex CLI (`codex`, team 2DC432GLL2) | chatgpt.com | approved | 17.1 s |
  | 19:00:44 | a VPN client | its vendor's metrics host | approved | 19.2 s |
  | 19:01:12 | a clipboard manager | a third-party analytics host | denied | 14.0 s |
  | 19:01:53 | a browser's helper process | an AI chat service's experiments host | approved | 12.3 s |
  | 19:02:36 | the same helper | one of the browser vendor's hosts | approved | 12.6 s |
  | 19:03:06 | the same helper | another of the browser vendor's hosts | approved | 18.4 s |

  The hook time runs from the hook's start to fx's exit, a few seconds after its verdict. Each hook ran `blackice
  approve` or `blackice deny` once, with `--app`, `--team` when the app had one, `--host`, and `--token`. The
  hook runner wrote the token as `[token]` in the log. `status` at 19:03:23 counted 6 approvals.

**Log lines.** The daemon's event log for the decisions on Apple's apps and the Codex CLI, with `stderr` left
out. The lines for the other apps are left out.

```
{"event":"ev-d7059872","ts":"2026-11-03T21:55:50.981Z","type":"verdict","verdict":"approved"}
{"duration_ms":13018,"event":"ev-d7059872","hook_line":15,"status":0,"ts":"2026-11-03T21:55:53.542Z","type":"hook_exited"}
{"event":"ev-635ef094","ts":"2026-11-03T21:55:56.190Z","type":"verdict","verdict":"denied"}
{"event":"ev-54c1c755","ts":"2026-11-03T21:55:56.327Z","type":"verdict","verdict":"denied"}
{"duration_ms":23141,"event":"ev-54c1c755","hook_line":15,"status":0,"ts":"2026-11-03T21:55:58.952Z","type":"hook_exited"}
{"duration_ms":23688,"event":"ev-635ef094","hook_line":15,"status":0,"ts":"2026-11-03T21:55:59.492Z","type":"hook_exited"}
{"event":"ev-cd6b222e","ts":"2026-11-03T21:56:20.163Z","type":"verdict","verdict":"approved"}
{"duration_ms":17145,"event":"ev-cd6b222e","hook_line":15,"status":0,"ts":"2026-11-03T21:56:24.159Z","type":"hook_exited"}
```

Each left-out `stderr` ends with the command fx ran and blackice's reply. geod's, as the run's output printed
it (the hook runner had already replaced the token):

```
Running blackice approve --app 'com.apple.geod' --host 'gsp57-ssl-background.ls.apple.com' --for 1h --token '[token]...
approved apple/com.apple.geod -> gsp57-ssl-background.ls.apple.com for 3600 s; 1 waiting connection, 0 allowed
```

**Recording.** None.

**Limits.**
- The build was a trial build. These changes came after it and have unit tests only (263 pass on the same Mac):
  - the step-2 fix;
  - the timeout rounded up to whole tens (63 would now be 70);
  - the two output lines wider than 80 columns above, now split.
- fx denied `nscurl` here, but approved it in P2-01. The skill tells the agent to deny when unsure, and `nscurl`
  is a generic tool. Which connections an agent approves depends on the model and varies between runs.
- fx was already signed in, so the sign-in path (`fx login vercel` run by the command) did not run. Nor did the
  paths for a missing fx, an unsigned fx, or a test with no answer, except in `AgentConnectTests`.
- The skill copied into `.fx/skills/blackice` keeps the mode it has in the app, 0755. Its files are the public
  skill, and the command checks folders only up to `.fx/skills`.
- When the filter started, macOS closed the SSH session that was following the log, as in P5-04.
- The run's log, outside the repository: `~/blackice-p5/trial-20261103-185430.log` on the Mac, with the first try in
  `trial-20261103-185318.log`.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 18:53:18 to 19:03:24 UTC−3 (21:53 to 22:03 UTC).
