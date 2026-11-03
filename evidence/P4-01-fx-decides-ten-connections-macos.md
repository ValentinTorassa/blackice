# P4-01: fx decides ten connections in a row with nobody at the keyboard (macOS)

**Claim.** In ask mode, fx 0.0.16, run by the hook, answered ten `nscurl` connections one event at a time, each with
that event's token, while nobody touched the keyboard. It approved four, which then got HTTP 200, and denied six,
whose connections were dropped. Nine of the ten answers matched the expected one; fx denied pypi.org, which was
expected to be approved. No event reached its deadline. This is phase 4's check: "fx decides ten test connections with
nobody touching the keyboard".

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled.

**Build.** Blackice.app 0.1.0, CFBundleVersion 3, as installed in `/Applications`, Developer ID signed and notarized
with `macos/scripts/sign.sh` (team M294LK997M). The commit was not recorded. It did not yet replace the token in the
hooks' stderr (see Limits).

**Agent.** fx 0.0.16 with the blackice skill and the rules that let it run only `blackice approve` and
`blackice deny` (`integrations/fx/README.md`), its keychain off, and a fixed allow rule for itself and its model
provider, Vercel's gateway. The model was not recorded.

**Configuration.** `~/.config/blackice/demo10.toml`:

```toml
# Phase 4 check: fx decides ten nscurl connections through the hook, with nobody at the keyboard.
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

# The agent sees only nscurl's connections; every other connection in the ask window gets no
# answer and is dropped at the timeout.
[[hook]]
on = "connection"
run = 'grep -q "com[.]apple[.]nscurl" "$BLACKICE_EVENT_FILE" || exit 0; FX_DISABLE_KEYCHAIN=1 PATH="/Applications/Blackice.app/Contents/MacOS:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME/.config/blackice/agent" fx ask "Use the blackice skill to decide whether to approve the pending connection"'
```

The `curl` rule plays no part here: every connection in the run came from `nscurl`, which has no rule.

**Run.** A script that a person started at the Mac (not in the repository):
1. `blackice start --config ~/.config/blackice/demo10.toml` (Touch ID 1 of 2; generation 18).
2. The daemon as a LaunchAgent with the same file. It registered with the extension.
3. Ten `nscurl` requests, one per host, in four batches of at most three at once, each batch after the previous one
   had finished: the daemon runs at most four hooks at once. From here nobody touched the keyboard.
4. `blackice mode accept-all` (Touch ID 2 of 2; generation 19), then the script read fx's verdicts from the event log
   and compared them with the answers it expected.

**Result.** Times in the last column are from the start of the first batch, as the run printed them.

| Host | Expected | fx's verdict | From event to verdict | fx ran | What `nscurl` saw |
|---|---|---|---|---|---|
| pastebin.com | denied | denied | 11.0 s | 14.2 s | NSURLErrorDomain -1005 at 11 s |
| api.github.com | approved | approved | 19.9 s | 22.5 s | `HTTP/2.0 200 OK` at 20 s |
| pypi.org | approved | **denied** | 25.6 s | 28.0 s | NSURLErrorDomain -1005 at 26 s |
| wetransfer.com | denied | denied | 11.5 s | 14.1 s | NSURLErrorDomain -1005 at 37 s |
| webhook.site | denied | denied | 13.0 s | 16.3 s | NSURLErrorDomain -1005 at 39 s |
| registry.npmjs.org | approved | approved | 18.9 s | 21.9 s | `HTTP/2.0 200 OK` at 45 s |
| 0x0.st | denied | denied | 10.6 s | 13.8 s | NSURLErrorDomain -1005 at 56 s |
| formulae.brew.sh | approved | approved | 18.6 s | 22.0 s | `HTTP/2.0 200 OK` at 64 s |
| developer.apple.com | approved | approved | 12.3 s | (no record) | `HTTP/1.1 200 OK` at 77 s |
| k9x2q7-1-1-1-1.nip.io | denied | denied | 13.8 s | (no record) | NSURLErrorDomain -1005 at 78 s |

Each verdict came from fx through `blackice approve` or `blackice deny` with the event's token: the filter logged ten
answers, all `token`, in the same order. "fx ran" is the hook's `duration_ms`; fx exits a few seconds after it
answers. The run's summary: `10 events from nscurl, 10 decided by fx, 9 as expected`.

**Log lines.** The run's output (each error line is cut by the script):

```
~/.config/blackice/demo10.toml: valid (mode ask, timeout 60 s, 2 allow rules, 1 hook)
blackice: start filtering (mode ask, 2 allow rules, 1 hook, generation 18)
Filter saved and enabled: mode ask, 2 allow rules, 1 hook, generation 18.

== Ten connections in four batches; from here nobody touches the keyboard
  pastebin.com               Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (11 s)
  api.github.com             HTTP/2.0 200 OK (20 s)
  pypi.org                   Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (26 s)
  wetransfer.com             Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (37 s)
  webhook.site               Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (39 s)
  registry.npmjs.org         HTTP/2.0 200 OK (45 s)
  0x0.st                     Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (56 s)
  formulae.brew.sh           HTTP/2.0 200 OK (64 s)
  developer.apple.com        HTTP/1.1 200 OK (77 s)
  k9x2q7-1-1-1-1.nip.io      Load failed with error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection w (78 s)

blackice: change the mode from ask to accept-all (generation 19)
Mode saved: mode accept-all, 2 allow rules, 1 hook, generation 19.

== What fx decided (from the daemon's event log)
  pypi.org                   denied     expected approved
  pastebin.com               denied     expected denied
  api.github.com             approved   expected approved
  wetransfer.com             denied     expected denied
  webhook.site               denied     expected denied
  registry.npmjs.org         approved   expected approved
  formulae.brew.sh           approved   expected approved
  0x0.st                     denied     expected denied
  developer.apple.com        approved   expected approved
  k9x2q7-1-1-1-1.nip.io      denied     expected denied
10 events from nscurl, 10 decided by fx, 9 as expected
```

The daemon's event log: each event and its verdict. Only these fields are copied, in the log's key order; `ip`,
`app_path` and the hook records, whose `stderr` holds the tokens, are left out:

```
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:24:51Z","event":"ev-246f55d1","host":"pypi.org","port":443,"ts":"2026-11-03T13:23:51.797Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:24:51Z","event":"ev-148aad22","host":"pastebin.com","port":443,"ts":"2026-11-03T13:23:51.802Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:24:51Z","event":"ev-745502db","host":"api.github.com","port":443,"ts":"2026-11-03T13:23:51.818Z","type":"event_received"}
{"event":"ev-148aad22","ts":"2026-11-03T13:24:02.784Z","type":"verdict","verdict":"denied"}
{"event":"ev-745502db","ts":"2026-11-03T13:24:11.675Z","type":"verdict","verdict":"approved"}
{"event":"ev-246f55d1","ts":"2026-11-03T13:24:17.415Z","type":"verdict","verdict":"denied"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:17Z","event":"ev-e4db0ee6","host":"wetransfer.com","port":443,"ts":"2026-11-03T13:24:17.503Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:17Z","event":"ev-d9383aa7","host":"webhook.site","port":443,"ts":"2026-11-03T13:24:17.517Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:17Z","event":"ev-8858e8ce","host":"registry.npmjs.org","port":443,"ts":"2026-11-03T13:24:17.528Z","type":"event_received"}
{"event":"ev-e4db0ee6","ts":"2026-11-03T13:24:28.955Z","type":"verdict","verdict":"denied"}
{"event":"ev-d9383aa7","ts":"2026-11-03T13:24:30.531Z","type":"verdict","verdict":"denied"}
{"event":"ev-8858e8ce","ts":"2026-11-03T13:24:36.382Z","type":"verdict","verdict":"approved"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:36Z","event":"ev-409ad7f3","host":"formulae.brew.sh","port":443,"ts":"2026-11-03T13:24:36.537Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:36Z","event":"ev-8be24de5","host":"0x0.st","port":443,"ts":"2026-11-03T13:24:36.814Z","type":"event_received"}
{"event":"ev-8be24de5","ts":"2026-11-03T13:24:47.438Z","type":"verdict","verdict":"denied"}
{"event":"ev-409ad7f3","ts":"2026-11-03T13:24:55.112Z","type":"verdict","verdict":"approved"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:55Z","event":"ev-d3a24a27","host":"developer.apple.com","port":443,"ts":"2026-11-03T13:24:55.701Z","type":"event_received"}
{"app_signing_id":"com.apple.nscurl","deadline":"2026-11-03T13:25:55Z","event":"ev-11d251e3","host":"k9x2q7-1-1-1-1.nip.io","port":443,"ts":"2026-11-03T13:24:55.851Z","type":"event_received"}
{"event":"ev-d3a24a27","ts":"2026-11-03T13:25:08.027Z","type":"verdict","verdict":"approved"}
{"event":"ev-11d251e3","ts":"2026-11-03T13:25:09.632Z","type":"verdict","verdict":"denied"}
```

The filter's control log (UTC−3):

```
2026-11-03 10:23:48.667 Df com.valentorassa.blackice.filter[49182:5b05a8] [com.valentorassa.blackice.filter:control] control configuration_installed mode ask, 2 allow rules, 1 hook, generation 18
2026-11-03 10:23:48.747 Df com.valentorassa.blackice.filter[49182:5b05a8] [com.valentorassa.blackice.filter:control] control xpc daemon_registered
2026-11-03 10:24:02.781 Df com.valentorassa.blackice.filter[49182:5b05a8] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:24:11.672 Df com.valentorassa.blackice.filter[49182:5b13dd] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 10:24:17.412 Df com.valentorassa.blackice.filter[49182:5b1305] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:24:28.952 Df com.valentorassa.blackice.filter[49182:5b1305] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:24:30.527 Df com.valentorassa.blackice.filter[49182:5b13dd] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:24:36.379 Df com.valentorassa.blackice.filter[49182:5b1b5f] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 10:24:47.435 Df com.valentorassa.blackice.filter[49182:5b13dd] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:24:55.108 Df com.valentorassa.blackice.filter[49182:5b1f02] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 10:25:08.024 Df com.valentorassa.blackice.filter[49182:5b13dd] [com.valentorassa.blackice.filter:control] control answer approve token approved
2026-11-03 10:25:09.628 Df com.valentorassa.blackice.filter[49182:5b1b5f] [com.valentorassa.blackice.filter:control] control answer deny token denied
2026-11-03 10:25:11.787 Df com.valentorassa.blackice.filter[49182:5b1b5f] [com.valentorassa.blackice.filter:control] control configuration_installed mode accept-all, 2 allow rules, 1 hook, generation 19
```

**Recording.** None published.

**Limits.**
- **pypi.org.** fx denied it after 28 s and printed only the deny command, with no reasons. In the same run it
  approved registry.npmjs.org and formulae.brew.sh for the same `nscurl`. This is the model's judgment, not blackice;
  the skill's guidance on package registries needs a look.
- **`nscurl` only.** Every connection came from `nscurl` (URLSession), which connects by name and can wait the whole
  timeout. Tools that connect to an address, such as `curl`, lose their connection while the event waits
  (`docs/plan.md`, "Connections named by their TLS server name").
- **Three at once.** The batches were sized to the daemon's limit of four hooks, so this run does not show what
  happens when more events arrive than hooks can run. That is the burst case of `macos/scripts/fault-test.sh`.
- The hook ran fx only for `nscurl`'s events. The Mac's own services got no answer and were dropped at the deadline.
- The event log has no `hook_exited` record for the last two events (developer.apple.com and the nip.io name); their
  verdicts are there.
- **Tokens in the event log.** In this build the runner did not yet replace the token in the hooks' stderr: the
  stderr fields of this run hold the full tokens fx printed with its commands, and no `[token]` marker. The tokens were
  spent or past their deadline within 60 s; none is copied here. The next build installed for a run should have the
  redaction (`docs/plan.md`, phase 3).
- The expected answers are the run script's. The commit and the model were not recorded.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 10:23 to 10:25 UTC−3 (13:23:51 to 13:25:11 UTC).
