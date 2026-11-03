# P2-02: build 4 in ask mode: curl gets through on the retry after fx approves, nscurl waits for fx (macOS)

**Claim.** With build 4 in ask mode, after a restart, the daemon loaded by `blackice agent install` registered and
took its hooks from the configuration the extension held. `curl https://api.github.com/zen` waited with its TCP
connection already ESTABLISHED; its first try failed after 16 s, fx approved it meanwhile, and the retry got HTTP 200 at
once. `nscurl https://registry.npmjs.org/` waited 28 s for fx's approval and got HTTP 200. fx denied
`curl https://pastebin.com/`, once for each of its two addresses. Name lookups through the system resolver kept
working, 13 flows passed as `apple_service`, and the hooks' stderr in the event log held `[token]` where fx printed the
token. This bears on phase 2's check (a `curl` waits, `approve` releases it), met for `curl` only on the retry after
the approval; on phase 3's (a hook approves one host and denies another); and on the daemon taking its configuration
from the extension (`docs/plan.md`, Daemon).

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. Restarted
before the run (see Limits).

**Build.** Blackice.app 0.1.0, CFBundleVersion 4, built from the `release-0.1.0` branch before its last two commits
(9b85c3a): without `start`'s check of the extension's XPC service (4754838) and without tipsd in the Apple services
table (b7c68ca). Signed by `macos/scripts/sign.sh` with the Developer ID Application certificate of team M294LK997M,
notarized and stapled. `systemextensionsctl` listed the extension as `0.1.0/4`. The app's CDHash was not recorded.

**Agent.** fx with the blackice skill and the rules that let it run only `blackice approve` and `blackice deny`
(`integrations/fx/README.md`), its keychain off, and a fixed allow rule for itself and its model provider, Vercel's
gateway. fx's version and the model were not recorded in the run's log.

**Configuration.** `~/.config/blackice/final.toml`:

```toml
# blackice build 4 on a Mac: ask mode with fx deciding through the hook, the Apple services table on
# (the default), names learned from DNS answers, and the daemon taking its hooks from the extension.
mode = "ask"
timeout_seconds = 60

# The deciding agent and its model provider (Vercel AI Gateway, with Vercel sign-in refresh).
[[allow]]
app = "com.vercel.fx"
team = "JW6Y669B67"      # Vercel, Inc
hosts = ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"]

# Tailscale (standalone build) may go anywhere, so its DNS and tunnel keep working.
[[allow]]
app = "io.tailscale.ipn.macsys.network-extension"
team = "W5364U7YZB"
hosts = ["*"]

# The agent sees only curl's and nscurl's connections; anything else gets no answer.
[[hook]]
on = "connection"
run = 'grep -q -E "com[.]apple[.](curl|nscurl)" "$BLACKICE_EVENT_FILE" || exit 0; FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME/.config/blackice/agent" fx ask "Use the blackice skill to decide whether to approve the pending connection"'
```

The filter logs a rule by the line of its `[[allow]]`: fx's rule is `rule_line_7`, Tailscale's `rule_line_13`. The
hook is on line 19.

**Run.** A script that a person started at the Mac (not in the repository):
1. It found build 4 already in `/Applications`, installed before the restart.
2. `blackice start --config ~/.config/blackice/final.toml` (Touch ID 1 of 2; generation 22).
3. `blackice agent install`, which takes no configuration: the daemon gets its hooks from the extension.
4. A name lookup for www.apple.com through the system resolver.
5. `curl https://api.github.com/zen`, with `netstat` 4 s in. Then it waited up to 50 s for fx's answer, printed
   `blackice pending`, and ran the same `curl` again.
6. `nscurl https://registry.npmjs.org/`.
7. `curl https://pastebin.com/`, then `blackice pending`.
8. `blackice mode accept-all` (Touch ID 2 of 2; generation 23) and `blackice agent uninstall`, then a summary from
   the daemon's event log and the filter's unified log.

**Result.**

| Connection | Event | fx, run by the hook | Verdict | From event to verdict | What the app saw |
|---|---|---|---|---|---|
| `curl` → api.github.com:443, first try | ev-59ab4fb3 | exit 0 after 18.7 s | approved | 16.0 s | exit 35, `SSL_ERROR_SYSCALL`, after 16 s |
| `curl` → api.github.com:443, retry | none: the approval covered it | | | | HTTP 200 at once |
| `nscurl` → registry.npmjs.org:443 | ev-d45e53a4 | exit 0 after 30.9 s | approved | 27.5 s | `HTTP/2.0 200 OK` after 28 s |
| `curl` → pastebin.com:443, first address | ev-7c753851 | exit 0 after 10.8 s | denied | 8.7 s | (curl moved on to the second address) |
| `curl` → pastebin.com:443, second address | ev-63b627d6 | exit 0 after 15.0 s | denied | 10.6 s | exit 7, "Couldn't connect to server", after 19 s |

Each verdict came from fx through `blackice approve` or `blackice deny` with the event's token: the filter logged four
answers, all `token`. fx approved both hosts for 10 minutes (`blackice pending` showed 600 s left on curl's approval).

- **The daemon.** It registered 0.17 s after the configuration was installed and logged
  `configuration_loaded` with generation 22, 1 hook and a 60 s timeout, the values of the configuration `start` had
  saved; every hook record names line 19. One event raised before it registered was not sent
  (`control event_not_sent no_daemon`) and its connection was dropped at the deadline.
- **curl's first try.** `netstat` showed the connection ESTABLISHED 4 s in, while the flow was paused: the server
  was already waiting for the TLS hello. The script expected the first try to be dropped at about 8 s
  (`hold_expired`). It failed at 16 s instead, at the moment fx's approval arrived: at 11:50:14.455 the filter let
  one paused flow through (`flow allow approved`), and 0.13 s later it allowed the retry under the new approval
  (`flow allow approval`, the only such line in the run). The flow lines name no app, so this rests on the times:
  curl's first connection looks held until the approval rather than dropped at 8 s, by when the server had given up
  on it. Why the 8 s hold did not drop it is not established. Either way, only the retry got through.
- **pastebin.com.** curl had two addresses for it. After fx denied the first, curl tried the second, which raised a
  new event, and fx denied that one too (`docs/plan.md`, "A denial is not remembered").
- **Name lookups.** The lookup for www.apple.com answered through the CNAME chain to Akamai, and the filter logged 62
  `flow allow system_resolver`.
- **The Mac's own services.** 13 flows passed as `apple_service`. Seven events came from other apps, which the hook
  left unanswered: nsurlsessiond to gateway.icloud.com twice (nsurlsessiond is kept out of the table on purpose),
  cloudd to gateway.icloud.com (covered by the table, so its address check must have failed; the filter logged 3
  flows asked about with `address_mismatch`, without naming them), tipsd to ipcdn.apple.com (not in build 4's table),
  dataaccessd to calendar.google.com (a Google calendar, which needs a rule), Brave's helper to go-updater.brave.com
  and Clipy to firebaselogging-pa.googleapis.com. Two of them timed out; the five still waiting at the switch to
  accept-all were cancelled, and their 21 paused flows were dropped with `configuration_changed`.
- **Tokens.** Each of the four hook records that ran fx has `stderr` with one `--token`, followed by `[token]`, and
  no string of 20 or more of a token's characters. The script's check: `hook stderr lines with a token: 0`.

**Log lines.** The run's output, cut where marked:

```
version 0.1.0 build 4
~/.config/blackice/final.toml: valid (mode ask, timeout 60 s, 2 allow rules, 1 hook)
blackice: start filtering (mode ask, 2 allow rules, 1 hook, generation 22)
Network extension activated.
Filter saved and enabled: mode ask, 2 allow rules, 1 hook, generation 22.
*	*	M294LK997M	com.valentorassa.blackice.filter (0.1.0/4)	Blackice Filter	[activated enabled]

== Daemon: blackice agent install (no --config; it takes the hooks from the extension)
Wrote ~/Library/LaunchAgents/com.valentorassa.blackice.daemon.plist for /Applications/Blackice.app/Contents/MacOS/blackice.
Loaded com.valentorassa.blackice.daemon in gui/501: launchd runs blackice daemon now and at each login.
[…]
blackice daemon: registered with the network extension; configuration generation 22, 1 hook, timeout 60 s

== DNS through the system resolver still works in ask mode
name: e6858.dsce9.akamaiedge.net
alias: www.apple.com www-apple-com.v.aaplimg.com www.apple.com.edgekey.net

== curl, first try (expected: dropped at about 8 s; fx decides meanwhile)
  netstat at 4 s:    1 ESTABLISHED
curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to api.github.com:443
  curl api.github.com: HTTP 000
  exit 35 after 16 s

== Wait for fx's answer (up to 50 s)
Approvals:
  apple/com.apple.curl -> api.github.com, 600 s left

== curl, retry (expected: HTTP 200 at once if fx approved)
  curl api.github.com: HTTP 200
  exit 0 after 0 s

== nscurl to registry.npmjs.org (URLSession: expected to wait for fx, then HTTP 200)
  nscurl registry.npmjs.org: HTTP/2.0 200 OK after 28 s

== curl to pastebin.com (expected: fx denies)
curl: (7) Failed to connect to pastebin.com port 443 after 19393 ms: Couldn't connect to server
  curl pastebin.com: HTTP 000
  exit 7 after 19 s
[…]
  hook stderr lines with a token: 0
```

The filter's decisions over the whole run, as the script counted them:

```
 197 flow ask no_rule
  75 flow drop hold_expired
  62 flow allow system_resolver
  60 flow drop timeout
  40 flow allow approved
  24 flow allow rule_line_7
  21 flow drop configuration_changed
  16 flow allow accept_all
  13 flow allow apple_service
  12 flow drop no_host
  12 flow allow inbound_not_filtered
   4 flow drop denied
   3 flow ask address_mismatch
   2 control answer deny token denied
   2 control answer approve token approved
   1 flow allow approval
   1 control xpc daemon_registered
   1 control event_not_sent no_daemon
   1 control configuration_installed mode ask
   1 control configuration_installed mode accept
```

The daemon's event log for the configuration and the events fx answered. Only these fields are copied, in the log's
key order; `ip`, `app_path`, `pid` and the hooks' `stderr` are left out:

```
{"generation":22,"hooks":1,"timeout_seconds":60,"ts":"2026-11-03T14:49:55.299Z","type":"configuration_loaded"}
{"app_signing_id":"com.apple.curl","deadline":"2026-11-03T14:50:58Z","event":"ev-59ab4fb3","host":"api.github.com","port":443,"ts":"2026-11-03T14:49:58.419Z","type":"event_received"}
{"event":"ev-59ab4fb3","hook_line":19,"ts":"2026-11-03T14:49:58.422Z","type":"hook_started"}
{"event":"ev-59ab4fb3","ts":"2026-11-03T14:50:14.464Z","type":"verdict","verdict":"approved"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T14:51:14Z","event":"ev-d45e53a4","host":"registry.npmjs.org","port":443,"ts":"2026-11-03T14:50:14.835Z","type":"event_received"}
{"event":"ev-d45e53a4","hook_line":19,"ts":"2026-11-03T14:50:14.836Z","type":"hook_started"}
{"duration_ms":18728,"event":"ev-59ab4fb3","hook_line":19,"status":0,"ts":"2026-11-03T14:50:17.149Z","type":"hook_exited"}
{"event":"ev-d45e53a4","ts":"2026-11-03T14:50:42.314Z","type":"verdict","verdict":"approved"}
{"app_signing_id":"com.apple.curl","deadline":"2026-11-03T14:51:42Z","event":"ev-7c753851","host":"pastebin.com","port":443,"ts":"2026-11-03T14:50:42.544Z","type":"event_received"}
{"event":"ev-7c753851","hook_line":19,"ts":"2026-11-03T14:50:42.547Z","type":"hook_started"}
{"duration_ms":30910,"event":"ev-d45e53a4","hook_line":19,"status":0,"ts":"2026-11-03T14:50:45.746Z","type":"hook_exited"}
{"event":"ev-7c753851","ts":"2026-11-03T14:50:51.219Z","type":"verdict","verdict":"denied"}
{"app_signing_id":"com.apple.curl","deadline":"2026-11-03T14:51:51Z","event":"ev-63b627d6","host":"pastebin.com","port":443,"ts":"2026-11-03T14:50:51.235Z","type":"event_received"}
{"event":"ev-63b627d6","hook_line":19,"ts":"2026-11-03T14:50:51.236Z","type":"hook_started"}
{"duration_ms":10849,"event":"ev-7c753851","hook_line":19,"status":0,"ts":"2026-11-03T14:50:53.394Z","type":"hook_exited"}
{"event":"ev-63b627d6","ts":"2026-11-03T14:51:01.871Z","type":"verdict","verdict":"denied"}
{"duration_ms":14955,"event":"ev-63b627d6","hook_line":19,"status":0,"ts":"2026-11-03T14:51:06.191Z","type":"hook_exited"}
```

The filter's control log (UTC−3):

```
2026-11-03 11:49:55.118 Df com.valentorassa.blackice.filter[619:16a5] [com.valentorassa.blackice.filter:control] control configuration_installed mode ask, 2 allow rules, 1 hook, generation 22
2026-11-03 11:49:55.196 Df com.valentorassa.blackice.filter[619:23c9] [com.valentorassa.blackice.filter:control] control event_not_sent no_daemon
2026-11-03 11:49:55.285 Df com.valentorassa.blackice.filter[619:23c9] [com.valentorassa.blackice.filter:control] control xpc daemon_registered 22
2026-11-03 11:50:14.455 Df com.valentorassa.blackice.filter[619:1677] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 11:50:42.305 Df com.valentorassa.blackice.filter[619:3079] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 11:50:51.210 Df com.valentorassa.blackice.filter[619:1677] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 11:51:01.862 Df com.valentorassa.blackice.filter[619:34b8] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 11:51:24.058 Df com.valentorassa.blackice.filter[619:364a] [com.valentorassa.blackice.filter:control] control configuration_installed mode accept-all, 2 allow rules, 1 hook, generation 23
```

The filter's lines when fx approved curl, and at the switch to accept-all, with the process and thread columns cut
(the 21 identical drops are shown once):

```
2026-11-03 11:50:14.455 [com.valentorassa.blackice.filter:flows] flow allow approved <private>
2026-11-03 11:50:14.455 [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 11:50:14.584 [com.valentorassa.blackice.filter:flows] flow allow approval <private>
2026-11-03 11:51:24.058 [com.valentorassa.blackice.filter:flows] flow drop configuration_changed <private>   (21 lines)
```

**Recording.** None published.

**Limits.**
- **curl's first try fails.** A tool that connects to an address gets through only on a retry after the approval,
  and `curl` retries only with `--retry`. The run does not show the first connection being dropped at 8 s, which is
  what `hold_expired` is for (see Result).
- **The hook chose what fx saw.** It ran fx only for `curl` and `nscurl`, so every other app's events went
  unanswered; their timeouts and cancellations say nothing about fx.
- **Tailscale.** The `hosts = ["*"]` rule for Tailscale's extension allowed nothing in this run (no
  `rule_line_13`), so it does not show that rule at work.
- **The restart.** Before it, the same build, installed over build 3 in place, kept filtering but had no XPC
  service, so the daemon and the CLI could not reach it (`docs/plan.md`, "Upgrades in place"). This run shows the
  build after a restart, not the upgrade.
- The build's commit comes from the person who built it; the CDHash, fx's version and the model were not recorded.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 11:49:53 to 11:51:30 UTC−3 (14:49 to 14:51 UTC).
