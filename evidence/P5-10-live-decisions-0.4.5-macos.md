# P5-10: remembered denials, connections by address and both agents deciding, with 0.4.5

**Claim.** With the published 0.4.5 in ask mode, four behaviors that `docs/plan.md` listed as not yet run on a Mac
worked on one: a deny is remembered and the app's next connections are dropped with no new event; a TCP connection
to a bare address is asked about by its address; an approval replaces a remembered denial and lets the app through
at once; and Claude Code and fx each decided real connections as the daemon's hook, in 3.3 to 6.6 s. Over the 24 h
before the run the two agents answered 376 events. Phase 4 (an agent decides) and phase 5 (hardening).

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi
(default route through the home router). Tailscale running, its DNS on (`CorpDNS: true`), with a `hosts = ["*"]`
rule for its network extension.

**Build.** Blackice.app 0.4.5, build 26, as published (Developer ID Application of team M294LK997M). Claude Code
2.1.318 (Homebrew cask) and fx, each connected with `blackice agent connect`.

**Configuration.** The owner's own `~/.config/blackice/blackice.toml`, not a test file: `mode = "ask"`,
`timeout_seconds = 60`, 21 `[[allow]]` rules (fx and Claude Code to their providers' hosts, browsers, chat apps and
VPN clients with `*`, and a few others), the fx hook at line 136 and the Claude Code hook at line 160, and
`answers = "claude-code"` in `[agent]`. No rule covers `nc`, `nscurl`, or `curl` to the hosts below.

**Run.** 6 November 2026, from a Claude Code session on the Mac, with the owner at the keyboard for Touch ID.

1. 12:41 UTC, nothing run on purpose: Claude Code's own telemetry connection raised an event, and the Claude Code
   hook denied it. Its retries are in the filter's log.
2. 12:43: `nc -z -w 45 1.1.1.1 80` (no name, port 80).
3. 12:44: `nscurl https://www.wikipedia.org/`; then `blackice approve --app com.apple.nscurl --host
   www.wikipedia.org --for 10m` (Touch ID) and the same `nscurl` twice.
4. 12:45: `blackice mode ask --agent fx` (Touch ID), `curl https://registry.npmjs.org/` twice, then `blackice mode
   ask --agent claude-code` (Touch ID).

**Result.**

1. Remembered denial. Claude Code denied `com.anthropic.claude-code → http-intake.logs.us5.datadoghq.com` in
   3780 ms. 105 s later two more connections of that app were dropped as `denied;remembered`, with no event and no
   hook; `blackice report` listed them as "denied a moment ago". Decided by the extension.
2. Connection by address. `nc` raised an event whose `host` is `1.1.1.1`, port 80; Claude Code denied it in 3280
   ms, and `blackice pending` then listed `com.apple.nc → 1.1.1.1` under "Denied, dropped without asking" for 10
   minutes. Before 4 November this connection was dropped as `no_host` with no event.
3. Approval over a denial. Claude Code denied `nscurl → www.wikipedia.org` in 3460 ms, and nscurl failed with
   NSURLError -1005, "The network connection was lost". `blackice approve` answered "Approved com.apple.nscurl →
   www.wikipedia.org for 10m, replacing its denial; nothing was waiting", and the next `nscurl` fetched the page
   (122,421 bytes, exit 0) with no new event.
4. fx as the answerer. With fx answering, `curl → registry.npmjs.org` raised an event and fx denied it in 6577 ms;
   curl failed after 7.3 s, and its second try failed in 0.08 s as a remembered denial. fx also denied Claude
   Code's telemetry connection in 4647 ms. Back on Claude Code, it answered the next events.
5. The day before. From 5 November 12:40 to 6 November 12:40 UTC the daemon received 389 events: Claude Code
   answered 350 (242 approve, 108 deny) and fx 26 (19 approve, 7 deny); 13 hooks printed no answer and 4 were killed
   at the 60 s deadline (3 of them fx's, at 17:05 to 17:11 on 5 November). Verdicts: 268 approved, 122 denied, 9
   timed out, 1 cancelled. Hook time at the median 3788 ms, p90 5434 ms (385 hooks).

**Log lines.** From `~/Library/Logs/blackice/events.jsonl` (`pid`, `app_path`, `deadline` and `stderr` left out):

```text
{"app_signing_id":"com.anthropic.claude-code","app_team_id":"Q6L2SF6YDW","event":"ev-e86e7dd3","host":"http-intake.logs.us5.datadoghq.com","ip":"2600:1901:0:9e23::","port":443,"ts":"2026-11-06T12:41:33.111Z","type":"event_received"}
{"duration_ms":3780,"event":"ev-e86e7dd3","hook_line":160,"status":0,"ts":"2026-11-06T12:41:36.893Z","type":"hook_exited"}
{"answer":"deny","event":"ev-e86e7dd3","hook_line":160,"ts":"2026-11-06T12:41:36.893Z","type":"hook_answer"}
{"app_signing_id":"com.apple.nc","event":"ev-fa430c3c","host":"1.1.1.1","ip":"1.1.1.1","port":80,"ts":"2026-11-06T12:43:35.182Z","type":"event_received"}
{"duration_ms":3280,"event":"ev-fa430c3c","hook_line":160,"status":0,"ts":"2026-11-06T12:43:38.463Z","type":"hook_exited"}
{"answer":"deny","event":"ev-fa430c3c","hook_line":160,"ts":"2026-11-06T12:43:38.463Z","type":"hook_answer"}
{"app_signing_id":"com.apple.nscurl","event":"ev-eae384d5","host":"www.wikipedia.org","ip":"195.200.68.224","port":443,"ts":"2026-11-06T12:44:20.628Z","type":"event_received"}
{"answer":"deny","event":"ev-eae384d5","hook_line":160,"ts":"2026-11-06T12:44:24.089Z","type":"hook_answer"}
{"app_signing_id":"com.apple.curl","event":"ev-4af029f8","host":"registry.npmjs.org","ip":"104.16.2.34","port":443,"ts":"2026-11-06T12:45:19.612Z","type":"event_received"}
{"duration_ms":6577,"event":"ev-4af029f8","hook_line":136,"status":0,"ts":"2026-11-06T12:45:26.192Z","type":"hook_exited"}
{"answer":"deny","event":"ev-4af029f8","hook_line":136,"ts":"2026-11-06T12:45:26.192Z","type":"hook_answer"}
```

From the filter's unified log (`log show --predicate 'subsystem == "com.valentorassa.blackice.filter" AND category
== "flows"'`), local time (UTC−3):

```text
2026-11-06 09:43:21.078 Df com.valentorassa.blackice.filter[74003:3ddee4] [com.valentorassa.blackice.filter:flows] flow drop denied;remembered app=Q6L2SF6YDW/com.anthropic.claude-code <private>
2026-11-06 09:43:21.095 Df com.valentorassa.blackice.filter[74003:3ddee4] [com.valentorassa.blackice.filter:flows] flow drop denied;remembered app=Q6L2SF6YDW/com.anthropic.claude-code <private>
```

**Limits.**

- The approved `nscurl` connection left no line in the filter's log, so this run does not show the hold until its
  TLS ClientHello for that app; other apps' approved connections on port 443 were logged as `approval;server_name`
  in the same minutes.
- Both agents denied `curl`, `nscurl` and `nc` to hosts a developer might well want (the npm registry, Wikipedia).
  That is what the deciders chose with the instructions they have, not a filter fault; the eval cases do not cover
  these hosts.
- The 13 hooks with no answer, 4 of them killed at the deadline, were looked into later the same day. Twelve were fx's,
  from 17:02 to 17:11 UTC on 5 November: its stderr shows it searching its capabilities for the skill instead of
  reading the event, and it printed no answer line or ran out the 60 s. That was before PR #49 gave fx's hook a
  two-sentence system prompt (merged at 19:58 UTC); with the new hook fx answered the 28 events after it. The
  thirteenth was Claude Code killed at the deadline on Datadog's host, at 12:08 UTC on 6 November, with nothing on
  stderr.
- Not covered: the fault tests (see the next entry), a first install, and Codex or opencode as the answerer.

**Date.** 6 November 2026.
