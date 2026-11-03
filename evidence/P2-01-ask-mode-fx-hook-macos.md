# P2-01: ask mode with fx deciding through the hook: two approvals, a denial and a timeout (macOS)

**Claim.** In ask mode, connections that no rule covered waited paused while the daemon ran the hook. fx, run by the
hook, answered with each event's token: it approved `nscurl` to api.github.com, which then got HTTP 200 about 18 s
after it started, approved a Homebrew `gh` (ad hoc signed, named by its cdhash) to api.github.com, and denied `nscurl`
to pastebin.com, which failed 16 s in. `nscurl` to example.org, whose event the hook passed over, was dropped at the
60 s deadline. This bears on phase 2's check (a connection waits, an approval releases it, no answer means the
deadline drops it), with `nscurl` in place of `curl` (see Limits), on phase 3's (a hook approves one host and denies
another) and on phase 4's agent deciding with nobody at the keyboard.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. Tailscale's
DNS was off for the run (`tailscale set --accept-dns=false`).

**Build.** The Blackice.app already installed in `/Applications`, Developer ID signed and notarized with
`macos/scripts/sign.sh` (team M294LK997M). Its build number and commit were not recorded in the run's log. It did not
yet replace the token in the hooks' stderr (see Limits).

**Agent.** fx 0.0.16 with the blackice skill and the rules that let it run only `blackice approve` and
`blackice deny` (`integrations/fx/README.md`), its keychain off, and a fixed allow rule for itself and its model
provider, Vercel's gateway. The model was not recorded.

**Configuration.** `~/.config/blackice/demo.toml`:

```toml
# blackice demo: ask mode, and fx decides through the hook. Loaded with one Touch ID; one more
# switches back to accept-all at the end.
mode = "ask"
timeout_seconds = 60

# The deciding agent and its model provider (Vercel AI Gateway, with Vercel sign-in refresh).
[[allow]]
app = "com.vercel.fx"
team = "JW6Y669B67"      # Vercel, Inc
hosts = ["ai-gateway.vercel.sh", "vercel.com", "api.vercel.com"]

[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]

# For the demo the agent sees only the two hosts the demo asks about; every other connection in
# the short ask window gets no answer and is dropped at the timeout.
[[hook]]
on = "connection"
run = 'grep -q -E "api[.]github[.]com|pastebin[.]com" "$BLACKICE_EVENT_FILE" || exit 0; FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME/.config/blackice/agent" fx ask "Use the blackice skill to decide whether to approve the pending connection"'
```

**Run.** A script that a person started at the Mac (not in the repository):
1. `blackice start --config ~/.config/blackice/demo.toml` (Touch ID; generation 16).
2. The daemon as a LaunchAgent, `blackice daemon --config` with the same file (its hooks are logged with this
   file's line 18). It registered with the extension.
3. Three `nscurl` requests at once, to `https://api.github.com/zen`, `https://pastebin.com/` and
   `https://example.org/`, then `blackice pending`. From here nobody touched the keyboard.

A Homebrew `gh` 2.102.0 connected to api.github.com 3 s after the `nscurl` requests; the run's log does not show its
output. The script's window closed before switching back, so the Mac stayed in ask mode until accept-all was set at
10:01:41 (generation 17).

**Result.**

| Connection | Event | Hook | Verdict | From event to verdict | What the app saw |
|---|---|---|---|---|---|
| `nscurl` → api.github.com:443 | ev-e072fe41 | fx, exit 0 after 21.8 s | approved | 17.6 s | `HTTP/2.0 200 OK` after 18 s |
| `nscurl` → pastebin.com:443 | ev-4089d579 | fx, exit 0 after 19.8 s | denied | 15.9 s | NSURLErrorDomain -1005, "The network connection was lost", after 16 s |
| `gh` (cdhash 2e3eb377…) → api.github.com:443 | ev-813d42e5 | fx, exit 0 after 16.5 s | approved | 12.7 s | not in the log |
| `nscurl` → example.org:443 | ev-91fd1910 | the `grep` found neither host; exit 0 after 35 ms | timed_out | 60.6 s (deadline 12:54:40Z) | not in the log |

Repeated connections joined their event: when `blackice pending` ran, the pastebin.com event held 7 connections and
the example.org one 16 (URLSession retrying while it waited). The Mac's own services were paused and waited too
(iCloud, CalDAV, Software Update, Maps, AuthKit); with no rule and no answer, they were dropped at the deadline.

**Log lines.** The run's output (the error line is cut):

```
~/.config/blackice/demo.toml: valid (mode ask, timeout 60 s, 2 allow rules, 1 hook)
blackice: start filtering (mode ask, 2 allow rules, 1 hook, generation 16)
Filter saved and enabled: mode ask, 2 allow rules, 1 hook, generation 16.
Waiting:
  ev-7fa76f98  apple/com.apple.networkserviceproxy -> mask-api.icloud.com:443 (2620:149:a41:580:e::1), 26 connections, 52 s left
  ev-9370328d  apple/com.apple.softwareupdated -> swscan.apple.com:443 (2600:1419:a400:595::1759), 3 connections, 52 s left
  ev-be657eb2  apple/com.apple.cloudd -> gateway.icloud.com:443 (2620:149:a41:580::2:8), 20 connections, 52 s left
  ev-fb3cd3bb  apple/com.apple.dataaccess.dataaccessd -> p404-caldav.icloud.com:443 (2620:149:a41:580::2:1), 24 connections, 54 s left
  ev-4089d579  apple/com.apple.nscurl -> pastebin.com:443 (2606:4700:10::6814:1d96), 7 connections, 55 s left
  ev-e072fe41  apple/com.apple.nscurl -> api.github.com:443 (4.228.31.149), 1 connection, 55 s left
  ev-91fd1910  apple/com.apple.nscurl -> example.org:443 (2606:4700:10::ac42:9ded), 16 connections, 55 s left
  ev-b0a4eb2d  apple/com.apple.akd -> gsas.apple.com:443 (17.179.252.18), 1 connection, 55 s left
  ev-e8d2beef  apple/com.apple.geod -> gsp57-ssl-background.ls.apple.com:443 (2620:149:a29:f000::5), 5 connections, 56 s left
  ev-813d42e5  cdhash/2e3eb377… -> api.github.com:443 (4.228.31.149), 1 connection, 57 s left
No approvals.
nscurl pastebin.com: Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost." … exit 0 after 16 s
nscurl api.github.com: HTTP/2.0 200 OK, exit 0 after 18 s
```

The daemon's event log for the four events. Only these fields are copied, in the log's key order; `ip`, `app_path`,
`pid` and the hooks' `stderr` are left out:

```
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T12:54:40Z","event":"ev-4089d579","host":"pastebin.com","port":443,"ts":"2026-11-03T12:53:40.019Z","type":"event_received"}
{"event":"ev-4089d579","hook_line":18,"ts":"2026-11-03T12:53:40.021Z","type":"hook_started"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T12:54:40Z","event":"ev-e072fe41","host":"api.github.com","port":443,"ts":"2026-11-03T12:53:40.032Z","type":"event_received"}
{"event":"ev-e072fe41","hook_line":18,"ts":"2026-11-03T12:53:40.033Z","type":"hook_started"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T12:54:40Z","event":"ev-91fd1910","host":"example.org","port":443,"ts":"2026-11-03T12:53:40.036Z","type":"event_received"}
{"event":"ev-91fd1910","hook_line":18,"ts":"2026-11-03T12:53:40.037Z","type":"hook_started"}
{"duration_ms":35,"event":"ev-91fd1910","hook_line":18,"status":0,"ts":"2026-11-03T12:53:40.072Z","type":"hook_exited"}
{"app_cdhash":"2e3eb377881dca0f24c407abcc4b933ec3d66ecf","deadline":"2026-11-03T12:54:42Z","event":"ev-813d42e5","host":"api.github.com","port":443,"ts":"2026-11-03T12:53:42.893Z","type":"event_received"}
{"event":"ev-813d42e5","hook_line":18,"ts":"2026-11-03T12:53:42.895Z","type":"hook_started"}
{"event":"ev-813d42e5","ts":"2026-11-03T12:53:55.632Z","type":"verdict","verdict":"approved"}
{"event":"ev-4089d579","ts":"2026-11-03T12:53:55.947Z","type":"verdict","verdict":"denied"}
{"event":"ev-e072fe41","ts":"2026-11-03T12:53:57.659Z","type":"verdict","verdict":"approved"}
{"duration_ms":16479,"event":"ev-813d42e5","hook_line":18,"status":0,"ts":"2026-11-03T12:53:59.373Z","type":"hook_exited"}
{"duration_ms":19804,"event":"ev-4089d579","hook_line":18,"status":0,"ts":"2026-11-03T12:53:59.824Z","type":"hook_exited"}
{"duration_ms":21763,"event":"ev-e072fe41","hook_line":18,"status":0,"ts":"2026-11-03T12:54:01.795Z","type":"hook_exited"}
{"event":"ev-91fd1910","ts":"2026-11-03T12:54:40.604Z","type":"verdict","verdict":"timed_out"}
```

The filter's control log (UTC−3): the configuration, the daemon's registration and the three answers, each with a
token:

```
2026-11-03 09:53:36.839 Df com.valentorassa.blackice.filter[49182:5a8e07] [com.valentorassa.blackice.filter:control] control configuration_installed mode ask, 2 allow rules, 1 hook, generation 16
2026-11-03 09:53:36.922 Df com.valentorassa.blackice.filter[49182:5a8aa8] [com.valentorassa.blackice.filter:control] control xpc daemon_registered
2026-11-03 09:53:55.615 Df com.valentorassa.blackice.filter[49182:5a8aa8] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 09:53:55.930 Df com.valentorassa.blackice.filter[49182:5a8aa8] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 09:53:57.642 Df com.valentorassa.blackice.filter[49182:5a8e07] [com.valentorassa.blackice.filter:control] control answer approve token approved
```

**Recording.** None published.

**Limits.**
- **`nscurl`, not `curl`.** Phase 2's check names `curl`. The same run with `curl` failed even when approved: `curl`
  connects to an address, so blackice reads the host from the TLS hello and holds it while the event waits, and the
  servers closed the connection before fx answered (`docs/plan.md`, "Connections named by their TLS server name").
  `nscurl` (URLSession) connects by name and is paused before its TCP connection.
- **The timeout is the hook's choice here.** The hook ran fx only for events that mention api.github.com or
  pastebin.com, so example.org's timeout shows the deadline dropping an unanswered connection, not fx failing to
  answer in time.
- **Tokens in the event log.** fx printed the commands it ran, token included, and this build copied them into the
  event log with the hook's stderr. The tokens were spent or past their deadline within 60 s; none is copied here. The
  runner now replaces them with `[token]` (`docs/plan.md`, phase 3).
- The run's log ends after the second result; example.org's timeout and `gh`'s approval come from the event log. The
  Mac stayed in ask mode for about eight minutes after the script's window closed.
- The build number, the commit and the model were not recorded.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 09:53 to 09:54 UTC−3 (12:53 to 12:54 UTC).
