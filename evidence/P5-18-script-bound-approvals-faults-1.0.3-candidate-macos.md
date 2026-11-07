# P5-18: the 1.0.3 candidate binds an interpreter's answers to its script, and passes the fault tests

**Claim.** A 1.0.3 candidate (build 35) replaced build 34 in place, with no restart, and passed all 29 checks of the
fault tests, the 50-host burst included. On the owner's configuration, with Claude Code answering, an approval of
Homebrew's python running the AWS CLI to STS covered that script only: the same python running `-c`, or another
script, to the same host raised an event of its own and was denied, as the owner's notes say. An approval by hand
with `--script` let that one script through, and its Touch ID dialog named the script. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, with
8.8.8.8 as its DNS server and Tailscale's DNS off.

**Build.** Blackice.app 1.0.3, build 35, from f54be2c, signed with the Developer ID Application of team M294LK997M,
notarized and stapled, `Blackice-1.0.3.zip` SHA-256 `4424c192708e74171424d0e874baf006383386daf022afbbb80240904e4ee012`.
Build 34 (from 5e271db, SHA-256 `8bf4a8f9ea000a8a985b16bfaa88a3ae5213514b1e5cbda9954e1c85df5e6cd4`) ran steps 1 to 4
first; build 35 adds only the Touch ID messages.

**Configuration.** The owner's file (22 rules, then 23, ask mode, Claude Code answering, the owner's notes), and for
the fault tests the script's own (ask mode, 1 rule, the `/bin/sh` test hook, 30 s to answer).

**Run.** 7 November 2026, 18:13 to 19:45 (UTC−3), from a Claude Code session on the Mac. The AWS calls used
`--no-sign-request`: no credentials were sent.

1. Build 34: the install script with `BLACKICE_ZIP` and `--force`, then `blackice start` (Touch ID).
2. `aws sts get-caller-identity --no-sign-request --region us-east-1`. Homebrew's AWS CLI 2.39.6 runs on Homebrew's
   python 3.15, which runs as `Python.app` (ad hoc, cdhash `321f5140b61e20fd457e38d8599da2332c720ea0`).
3. That python with `-c` and urllib to `https://sts.us-east-1.amazonaws.com/`, then running `probe.py` from a
   temporary folder to the same host; `blackice pending`.
4. `blackice approve --cdhash 321f5140… --host sts.us-east-1.amazonaws.com --for 10m --script <probe.py's path>`,
   three times. Each dialog stayed up for 2 minutes with nobody at the Mac; a screenshot showed it on screen.
5. Build 35: the install script, then `macos/scripts/fault-test.sh` (two Touch IDs), then `blackice start` with the
   owner's file (Touch ID).
6. Steps 2 and 3 again, then step 4's command (Touch ID), then `probe.py`, `-c` and `aws` once more.

**Result.**

1. `1.0.3/34 [activated enabled]`, ask mode, no restart.
2. Approved by Claude Code for 24 hours in 3.9 s. `pending` lists `cdhash 321f5140 → sts.us-east-1.amazonaws.com
   24h  running /opt/homebrew/bin/aws`; the event log has event `ev-869cae7a` with that `app_script`.
3. Each raised an event of its own, `ev-53a0deab` with no `app_script` and `ev-ac3d360c` with probe.py's path, and
   Claude Code denied both (2.7 and 2.3 s). `pending` lists the two denials as `with no script` and
   `running …/probe.py`, the second with `--script` on its approve line, and the approval of `aws` beside them.
4. The dialog read "let cdhash/321f5140…, running …/probe.py, reach sts.us-east-1.amazonaws.com for 10 min".
   Build 34 then printed "Touch ID was cancelled, so nothing changed." and exited 77: blackice's own 2-minute limit
   had passed (coreauthd: started 18:35:03, invalidated by the client 18:37:03). Build 35 says "No answer to Touch
   ID within 2 minutes" in that case.
5. `1.0.3/35 [activated enabled]` with no restart. The fault tests: 29 of 29 checks pass (`fault-test-35.log`):
   the connection with no daemon is dropped at the deadline, the hung hook is killed at it, the burst raises one
   event for the 70 connections to example.org (64 held, 76 dropped as `ask_capacity`) and one for each of the 50
   hosts, runs at most 4 hooks with 46 waiting, `curl` reaches pypi.org during it, launchd starts the killed
   daemon again, and the switch to accept-all lets the 2 waiting connections go and cancels their events. The
   owner's file loaded again, now with 23 rules: another session had added one with `approve --save`.
6. As in steps 2 and 3, on build 35. The approval printed "Approved cdhash 321f5140 → sts.us-east-1.amazonaws.com
   (running …/probe.py) for 10m, replacing its denial". probe.py's connection to STS then went through (`allow
   approval;server_name`, no new event); STS answers `302` to `https://aws.amazon.com/iam`, and the redirect raised
   its own event for probe.py, which Claude Code denied. `-c` stayed denied (`denied;remembered`), and `aws` went
   on through its approval.

Decided by: the extension, the daemon and Claude Code.

**Also.** The unit tests (532) pass locally, with the cooperative pool cut to one thread, and on CI. Claude Code's
eval with the new instructions: 33 of 33. Codex's: 32 of 33; the miss (case 29, uv's python to PyPI) passed six
reruns.

**Limits.**

- The script name comes from the process's command line, so binding narrows what an answer covers and proves
  nothing: any program can start the same python with `/opt/homebrew/bin/aws` as its first argument.
- The menu's answers to an interpreter's event were checked by unit tests, not on the Mac.
- An approval of a script by a relative path, which `pending` shows when the process's folder cannot be read, was
  not seen live.

**Date.** 7 November 2026.
