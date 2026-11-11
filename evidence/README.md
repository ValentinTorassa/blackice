# Evidence

Each file here records one real run on a Mac, made by the people building blackice; none is an independent test.
The README, the docs and the site describe something as working only when an entry here records it. Unit tests,
dry runs and code that compiles are not evidence of that kind and get no entry.

## Naming

`P<phase>-<nn>-<what>-macos.md`: the phase in [`docs/plan.md`](../docs/plan.md) whose check the run bears on, a
two-digit number within that phase, and what the run shows, for example `P0-01-team-signed-probe-blocked-macos.md`.
The scheme follows blackice-poc's `P0-xx` entries, where the prefix named a checkpoint of its v0. Add the file after
the run, never before it.

## What an entry records

- **Claim**: one or two sentences, and the phase check it bears on.
- **Platform**: Mac model, macOS version and build, architecture, and whether System Integrity Protection is on.
- **Build**: the app's version and build number, the commit if it was recorded, and how it was signed.
- **Configuration**: the `blackice.toml` used, inline.
- **Run**: what was run, in order, and who did what.
- **Result**: what happened, and which part decided: the extension, the daemon, a hook or a person.
- **Log lines**: the lines from the filter's unified log, the daemon's event log and the run's output that show it.
- **Recording**: a link, if there is one.
- **Limits**: what the run does not show.
- **Date**.

## Copying from the logs

- Never copy an event token. The event log keeps up to 2 KiB of each hook's stderr, and an agent that prints the
  commands it runs prints the token with them (`--token '…'`). Copy the fields an entry needs and leave `stderr` out.
- Replace home directories with `~`, and leave out apps, hosts and paths that are not part of the run.
- The filter logs each flow's app and host as `<private>`; only the verdict and the reason are public. The event log
  has the app and host, so an entry ties the two together through the event ID and the times.
- Failed runs get their own entries too, named for what failed.

## Entries

| Entry | Phase | What it shows |
|---|---|---|
| [P0-01](P0-01-team-signed-probe-blocked-macos.md) | 0 | In block-all a binary signed with our Team ID and named by no rule is refused, and `curl` with a rule still reaches its host. |
| [P2-01](P2-01-ask-mode-fx-hook-macos.md) | 2, 3, 4 | Ask mode with fx deciding through the hook: two approvals, one denial, one connection dropped at the deadline. |
| [P2-02](P2-02-curl-passes-on-retry-nscurl-waits-macos.md) | 2, 3 | Build 4 in ask mode: the daemon takes its configuration from the extension; `curl`'s first try fails and its retry passes after fx approves; `nscurl` waits for fx and passes; no token in the event log. |
| [P4-01](P4-01-fx-decides-ten-connections-macos.md) | 4 | fx decides ten connections in a row with nobody at the keyboard; nine match the expected answer. |
| [P5-01](P5-01-faults-macos.md) | 5 | The fault tests: 24 checks pass; the last 4 of case 4 fail, three because the second Touch ID was cancelled and one because `blackice pending` rejected the extension's reply. |
| [P5-02](P5-02-homebrew-upgrade-from-release-macos.md) | 5 | 0.1.0 installed with Homebrew from the published release over build 4: signed, notarized and accepted; `start` finds the upgraded extension unreachable and exits with 75; after a restart its XPC service answers. |
| [P5-03](P5-03-curl-install-script-sandbox-macos.md) | 5 | The curl install script: the one-liner stops on a Homebrew install; a copy aimed at a temporary folder downloads 0.1.0, checks checksum, signature and notarization, installs it and writes the command; `--force` replaces another version. |
| [P5-04](P5-04-install-start-faults-from-release-macos.md) | 5 | From the published 0.2.1: uninstalling by following `docs/install.md`, the curl one-liner into `/Applications` (checksum, signature and notarization checked), the first `start`'s three numbered steps, and the fault tests with all 28 checks passing. |
| [P5-05](P5-05-agent-connect-fx-macos.md) | 4, 5 | A trial build: `blackice agent connect fx` finds fx, gives it its own home, tests it on a sample event (approved in 21 s), adds its rule and hook, and turns ask mode on with one Touch ID; fx then denies two `nscurl` requests and decides seven connections of other apps. The first try stopped on a folder others could read, since fixed. |
| [P5-06](P5-06-onboarding-from-zero-macos.md) | 4, 5 | 0.3.0 candidates, from no blackice and no fx: the one-liner, the first `start`'s lists, fx installed and signed in by `start`; its test failed with HTTP 403 (a Vercel team with no card), and with an earlier sign-in `agent connect fx` loaded ask mode, where fx approved two `nscurl` requests in about 5 s. Builds 9 and 10 failed on the way, in three places, each fixed in build 11. |
| [P5-07](P5-07-apple-tools-invalid-signature-macos.md) | 2, 5 | In ask mode, build 11 dropped Apple's developer tools as `invalid_signature` without asking: `notarytool` (build 12 could not be notarized) and git over HTTPS (24 ms). Build 13 checks a Team ID against Developer ID, Apple's and the Mac App Store's signatures: `git-remote-http` and `notarytool` waited, fx approved each in about 5 s, and both worked. On that Mac 117 tools and 5 Mac App Store apps go from refused to accepted, and nothing else changes. |
| [P5-08](P5-08-onboarding-published-0.3.0-recorded-macos.md) | 4, 5 | From the published 0.3.0, recorded: the site's one-liner, then one `blackice start` to ask mode with fx answering in 1 min 16 s (lists, Touch ID, System Settings, fx's installer and sign-in, a test approved in 16 s, the rule and hook, the daemon). Enter on an app closed the list with nothing picked, fixed in 0.3.1. In the next ten minutes a VPN client's extension sent bursts of events, and with 4 hooks at most, 62 of 94 got no hook and 31 connections were dropped at the deadline. |
| [P5-09](P5-09-hook-queue-faults-0.3.2-candidate-macos.md) | 5 | A 0.3.2 candidate (build 15, not published) in the fault tests: the burst runs at most 4 hooks and the rest wait for a slot (46 waited; those left with under 10 s dropped as `deadline_near`) while the Mac keeps working. 22 of 28 checks pass; the 6 that fail are `example.com` and `www.example.com`, which did not resolve on that network. The upgrade from an unreachable 0.3.1 answered without a restart. |
| [P5-10](P5-10-live-decisions-0.4.5-macos.md) | 4, 5 | The published 0.4.5 on the owner's own configuration: a deny remembered for the app's next connections (`denied;remembered`, no event), `nc` to a bare address asked about by its address, an approval replacing a denial, and Claude Code and fx deciding real connections as the daemon's hook in 3.3 to 6.6 s; 376 answers in the 24 h before. |
| [P5-11](P5-11-faults-0.4.5-macos.md) | 5 | The published 0.4.5 in the fault tests: all 29 checks pass, the two `example.com` cases and the change to accept-all that lets paused connections go included. The script now reads 0.4.5's `pending` and keeps its own `log stream` copy, since `log show` kept none of the filter's lines on a nearly full disk. |
| [P5-12](P5-12-install-from-zero-0.4.6-macos.md) | 4, 5 | From no blackice to ask mode with the published 0.4.6: the one-liner in 2 s, one `blackice start` in about 54 s with Claude Code (test approved in 3 s), and the menu bar app opened by `start` itself, before the daemon and the login question. After putting the owner's file back, `start` kept accept-all (a bug). |
| [P5-13](P5-13-upgrade-in-place-0.4.7-macos.md) | 5 | From the published 0.4.6 to 0.4.7 in place, in ask mode: the script with `--force` and one `start`, no restart. The new extension started in ask mode with the old one's saved configuration, 0.27 s after the old one stopped; the old one dropped the 52 connections it held. Claude Code went on answering with 0.4.7's instructions. |
| [P5-14](P5-14-codex-live-0.4.7-macos.md) | 4 | Codex answering real connections with 0.4.7: 80 in an hour, all in time, median 6.2 s. It read the owner's notes as the whole list of what a tool may reach and denied `curl` to fonts.gstatic.com; the instructions now say the notes only add. Eval with the notes: Codex 31 of 33, Claude Code and fx 33 of 33. |
| [P5-15](P5-15-release-1.0.0-gate-macos.md) | 5 | The 1.0.0 candidates: build 29 upgraded 0.4.7 in place with no restart (0.32 s between extensions), passed 29 of 29 fault checks and went from no blackice to accept-all in 24 s; build 30, released, upgraded build 29 in place and in its first start wrote 27 rules for two VPN tunnels and four common apps with their helpers, the split tunneling left unticked, in ask mode with Claude Code 31 s after the window opened. |
| [P5-16](P5-16-protected-folders-1.0.1-candidate-macos.md) | 2, 5 | 1.0.0 dropped every connection of a program run from `~/Documents` or `~/Downloads` as `unknown_identity`, with no event (9,072 drops of deepsec's Codex in six minutes); the same `gh` connected from elsewhere. A 1.0.1 candidate named a Developer ID `adb` copied to `~/Documents` by its kernel cdhash, raised an event with its path, and Claude Code answered it. |
| [P5-17](P5-17-deepsec-fixes-1.0.2-candidate-macos.md) | 5 | A 1.0.2 candidate replaced 1.0.1 in place with no restart; its install script, run again on the same version, checked the installed app's signature and kept it; a program with a line break in its file name raised an event without its path, and `blackice pending` still listed what waited. |
| [P5-18](P5-18-script-bound-approvals-faults-1.0.3-candidate-macos.md) | 4, 5 | A 1.0.3 candidate replaced the last one in place and passed 29 of 29 fault checks; with Claude Code answering, an approval of python running the AWS CLI to STS covered that script only, while `-c` and another script of the same python raised their own events and were denied; `approve --script` let one script through, its Touch ID dialog naming it. |
| [P5-19](P5-19-sleep-and-address-fixes-faults-1.0.4-candidate-macos.md) | 5 | A 1.0.4 candidate replaced 1.0.3 in place with no restart and passed 29 of 29 fault checks on its second run (28 on the first, where a switch to accept-all from the menu bar came before the script's). It fixes two faults seen in 18 hours of 1.0.3: hooks the Mac slept through holding every slot, and approved connections dropped when a host's addresses rotate within seconds; both checked by unit tests, neither seen live. |
| [P5-20](P5-20-mismatch-drop-faults-1.0.5-candidate-macos.md) | 5 | A 1.0.5 candidate replaced 1.0.4 in place and in ask mode dropped at once connections whose app and host something names but whose address mismatched: 48 in two hours of normal use, none asked about, where 1.0.4 raised an event no answer could act on. In three fault-test runs every check passed at least once and none passed all 29: case 4's Touch ID came after the test's deadline in two, and after midnight the burst filled the 1,024 places for connections waiting on a lookup. |
| [P5-21](P5-21-saved-approvals-repeated-drops-1.0.6-candidate-macos.md) | 5 | Three builds of 1.0.6, the last of them the candidate, brought the filter's approvals back after `blackice stop`, two upgrades in place and a restart of the Mac. After that restart identityservicesd opened about 430 connections a second to a peer the filter drops; the candidate delays an app's TCP connections once 64 were dropped within 2 s, which took 12 loops from 5,452 tries in 10 s to 184, and bounds the log lines of a UDP loop, whose work it does not bound. The fault tests passed 29 of 29, and 23 on a network whose DNS server does not resolve example.com. In 81 minutes of normal use the delay never started: it counts only connections dropped as they start, and one app's 7,586 drops came later. |
| [P5-22](P5-22-upgrade-hold-echo-faults-1.0.7-candidate-macos.md) | 5 | The 1.0.7 candidate replaced a build in place with the filter turned off first and an ICMP echo request sent to loopback while it waited: the kernel, at the socket of symptomsd that had held the three upgrades before for 47 to 116 s, let go in 0.42 s, and the Mac never had two filters. Waiting alone, 30 s or 90, had not spared those three: no new connection got through for 17 to 29 s past the wait. A filter going with none in its place held nothing up, and a `ping` of loopback ended a hold in a `stop` within 0.01 s. On the candidate's filter a full table of DNS flows cost no lookup, a link-local address was asked about and loops of dropped connections were delayed or bounded; six approved connections in one run of 180 were still dropped as `address_mismatch`. The fault tests passed 29 of 29, twice on build 55 and once on the candidate. |

Not recorded yet: the System Settings steps that 0.2.1 prints for macOS 14 and 15, a first `start` that signs fx in
to a team with a card and loads ask mode by itself, and `agent connect` from a released build. The upgrade from build 3 to build 4, which first left the
extension without an XPC service until a restart, has no entry; P5-02 records the same with build 5.
