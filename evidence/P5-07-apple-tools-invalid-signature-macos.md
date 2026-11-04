# P5-07: Apple's developer tools were dropped as invalid_signature in ask mode; build 13 asks about them (macOS)

**Claim.** In ask mode, candidate build 11 of 0.3.0 dropped every connection of Apple's developer tools installed
with the Command Line Tools as `invalid_signature`. No event reached the hook and no rule could name them:
- `notarytool` lost its connection to Apple's notary service, so build 12 could not be notarized.
- `git ls-remote` over HTTPS failed after 24 ms, and again after 45 ms.

Those tools are signed by Apple and carry Team ID 59GAB85EFG. The filter checked any code with a Team ID only in the
Developer ID form, where the team is the leaf certificate's OU, and Apple's certificate does not have it there. Mac
App Store apps fail the same check.

Build 13 (78730ee) checks a Team ID against three kinds of signature: Developer ID, Apple's own, and the Mac App
Store's. With it in ask mode, `git-remote-http` and `notarytool` waited under their own identity, fx approved each
about 5 s later, and both commands worked at the first try.

A check of the Mac's apps and tools found 117 tools and 5 Mac App Store apps that the old requirement refused and
the new one accepts. It found no other difference.

This bears on phase 2's identity check in ask and block-all, and on phase 5's question of whether a developer can
work with ask mode on.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. Command Line
Tools at `/Library/Developer/CommandLineTools`, no Xcode. fx 0.0.16 as in P5-06.

**Build.**
- Build 11 (2474adc), as installed at the end of P5-06, for the failures.
- Build 12 (552a3e1) was built and signed but not notarized (below), and never installed.
- Build 13 (78730ee): Blackice.app 0.3.0, signed with the Developer ID, notarized and stapled. `Blackice-0.3.0.zip`
  SHA-256 `4bc2548f7d69fed8df4a12b31dc4610dfe81a71e6673e18a000fec48425d6b86`.

**Configuration.** The file P5-06 ended with: ask mode, `timeout_seconds = 60`, fx's `[[allow]]` rule and its hook.
It did not change during these runs.

**Run.**
1. 21:33:31, build 12 built and signed over SSH, with build 11 in ask mode. The filter's unified log was streamed to
   a file during the build.
2. 21:37:09, `git ls-remote https://github.com/ValentinTorassa/blackice HEAD` over SSH.
3. Two checks written for this, run on the Mac:
   - one over the running processes: their signing information, and the old requirement against it;
   - one over the code on disk: `/Applications/*.app`, `/System/Applications/*.app`, every file in the Command Line
     Tools' `usr/bin`, `git-remote-http` and `git-remote-https`, fx, curl, nscurl and ssh. For each it checked the
     old requirement and the new one with `SecStaticCodeCheckValidity` and strict validation.
4. 21:49:13, a script in a Terminal window on the Mac, with the person at the Mac for Touch ID and System Settings:
   - `git ls-remote` again with build 11;
   - `blackice mode accept-all` (Touch ID 1), so that `notarytool` could reach Apple;
   - build 13 signed, notarized and packaged;
   - `blackice agent uninstall` and `blackice stop` (Touch ID 2). Nobody touched the sensor in time at 21:53:09, so
     that run stopped and changed nothing. It was started again from this step at 21:53:51.
5. 21:53:55, the install one-liner with build 13's zip (`BLACKICE_ZIP`), then `blackice start` with the same file
   (Touch ID 3, System Settings), then `blackice agent install`.
6. 21:54:36, in ask mode: `git ls-remote` as above, then `xcrun notarytool history`, then the daemon's events and
   the filter's verdicts for those seconds.
7. 21:54:52, the person kept ask mode on. `status` at 21:56:20 showed ask mode and 10 approvals.

**Result.**

- **Build 12's notarization.** `notarytool` printed "Error: HTTPError(statusCode: nil, error: Error
  Domain=NSURLErrorDomain Code=-1005 "The network connection was lost." …)" for
  `https://appstoreconnect.apple.com/notary/v2/submissions`. The filter logged six `flow drop invalid_signature`
  lines between 21:34:39.305 and 21:34:39.336, and no event reached the daemon. Notarization had failed twice
  earlier that day while the Mac was in ask mode; the filter's lines for those were not kept.
- **git over HTTPS, build 11.** "fatal: unable to access 'https://github.com/ValentinTorassa/blackice/': Failed to
  connect to github.com port 443 after 24 ms: Couldn't connect to server". The filter logged one `flow drop
  invalid_signature` at 21:37:09.700. At 21:49:14 the same command failed after 45 ms, with one more such line at
  21:49:14.145.
- **Why.** `codesign -dvvv` on the Command Line Tools' `git-remote-https`, `git`, `swift-package` and `notarytool`
  shows Authority "Software Signing", the designated requirement `identifier "…" and anchor apple`, and
  `TeamIdentifier=59GAB85EFG`. Build 11 checked code with a Team ID against `anchor apple generic and identifier
  "…" and certificate leaf[subject.OU] = "<Team ID>"`. Apple's leaf certificate does not carry the Team ID in its
  OU, so the check failed, and in ask mode the policy drops code with an invalid signature before it asks. A
  messaging app from the Mac App Store shows Authority "Apple Mac OS Application Signing" and a designated
  requirement on leaf field 1.2.840.113635.100.6.1.9, with the developer's Team ID in the code directory, and it
  fails the same way.
- **The checks.** Among the running processes, two failed the old requirement: the Command Line Tools' `python3`
  and a Mac App Store app's service extension. On disk:

  | Code | Count | Old requirement | New requirement |
  | --- | --- | --- | --- |
  | Apple's developer tools, Team ID 59GAB85EFG | 117 | refused | accepted |
  | Mac App Store apps, the developer's Team ID | 5 | refused | accepted |
  | Developer ID apps and tools | 37 | accepted | accepted |
  | Apple platform code, no Team ID | 51 | accepted | accepted |
  | Unsigned (mostly scripts) | 20 | not checked | not checked |

  The 117 include git, git-remote-http, python3, clang, swift-frontend, swift-package, notarytool and stapler.
  The 5 are Apple's three iWork apps, a messaging app and a remote desktop client.
- **The change** (78730ee, `CodeIdentity.requirementText`). Code with a Team ID must satisfy `identifier "…" and
  (anchor apple or anchor apple generic and (certificate leaf[subject.OU] = "<Team ID>" or certificate
  leaf[field.1.2.840.113635.100.6.1.9] exists))`. The filter keeps the Team ID from the code directory, so the tools
  are named `59GAB85EFG/<signing identifier>` and stay out of the built-in list of macOS services, which counts
  only code with no Team ID. The same requirement serves `blackice init` and the first `start` when they name an
  app on disk.
- **Build 13 in ask mode.** `blackice start` loaded ask mode with 1 rule and 1 hook, and `status` showed the daemon
  running the hook. Then:

  ```
  $ git ls-remote https://github.com/ValentinTorassa/blackice HEAD
  29cc6b65c52c7247d6fc5261463551e060af2f64	HEAD
  (exit 0 after 6 s)
  $ xcrun notarytool history --keychain-profile … --keychain …
  Successfully received submission history.
  …
  (exit 0 after 6 s)
  ```

  | Verdict at | App (as the event named it) | Host | fx | After the event |
  | --- | --- | --- | --- | --- |
  | 21:54:42.008 | `59GAB85EFG/com.apple.git-remote-http` | github.com | approved for 10 minutes | 5.0 s |
  | 21:54:48.130 | `59GAB85EFG/com.apple.gke.notary.tool` | appstoreconnect.apple.com | approved for 1 hour | 5.5 s |

  In the same seconds fx also approved connections of Apple's location service, a chat app and a VPN client. From
  21:54:00 to the end of the run, the filter logged no `invalid_signature`.

**Log lines.** The daemon's event log for the two events, with `stderr` left out:

```
{"app_path":"/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-http","app_signing_id":"com.apple.git-remote-http","app_team_id":"59GAB85EFG","deadline":"2026-11-04T00:55:36Z","event":"ev-edaedc65","host":"github.com","ip":"4.228.31.150","port":443,"ts":"2026-11-04T00:54:36.962Z","type":"event_received"}
{"event":"ev-edaedc65","hook_line":20,"pid":45353,"ts":"2026-11-04T00:54:36.963Z","type":"hook_started"}
{"event":"ev-edaedc65","ts":"2026-11-04T00:54:42.008Z","type":"verdict","verdict":"approved"}
{"app_path":"/Library/Developer/CommandLineTools/usr/bin/notarytool","app_signing_id":"com.apple.gke.notary.tool","app_team_id":"59GAB85EFG","deadline":"2026-11-04T00:55:42Z","event":"ev-bbfabdd2","host":"appstoreconnect.apple.com","ip":"2600:1419:1200:d::217:a4f9","port":443,"ts":"2026-11-04T00:54:42.650Z","type":"event_received"}
{"event":"ev-bbfabdd2","hook_line":20,"pid":45368,"ts":"2026-11-04T00:54:42.651Z","type":"hook_started"}
{"duration_ms":7683,"event":"ev-edaedc65","hook_line":20,"status":0,"ts":"2026-11-04T00:54:44.646Z","type":"hook_exited"}
{"event":"ev-bbfabdd2","ts":"2026-11-04T00:54:48.130Z","type":"verdict","verdict":"approved"}
{"duration_ms":8385,"event":"ev-bbfabdd2","hook_line":20,"status":0,"ts":"2026-11-04T00:54:51.036Z","type":"hook_exited"}
```

The end of git's left-out `stderr`, which fx printed as it ran blackice (fx shortens the token's line):

```
Running blackice approve --app 'com.apple.git-remote-http' --team '59GAB85EFG' --host 'github.com' --for 10m --token '[token]...
approved 59GAB85EFG/com.apple.git-remote-http -> github.com for 600 s; 1 waiting connection, 1 allowed
```

The filter's unified log, build 12's notarization (the app and host are private):

```
2026-11-03 21:34:39.305 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
2026-11-03 21:34:39.307 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
2026-11-03 21:34:39.309 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
2026-11-03 21:34:39.310 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
2026-11-03 21:34:39.334 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
2026-11-03 21:34:39.336 Df com.valentorassa.blackice.filter[41479:71d56] [com.valentorassa.blackice.filter:flows] flow drop invalid_signature <private>
```

**Recording.** None.

**Limits.**
- No Mac App Store app connected during the run with build 13. For them the evidence is the check on disk and the
  unit test `macAppStoreAppsKeepTheirTeam`.
- A rule naming `59GAB85EFG/com.apple.git-remote-http` was not tried. fx's approvals named it, and approvals match
  the same identity rules do.
- Block-all was not run. It goes through the same identity check before its rules.
- Apps signed in other Apple forms, such as iPhone and iPad apps on the Mac and TestFlight builds, are outside the
  new requirement and were not checked.
- The filter's own app and host fields are private, so the lines of build 12's notarization are tied to `notarytool`
  by their times only.
- In the 16 s of the try the filter also dropped 55 flows as `no_host`, flows with no host name that are not TLS
  over TCP. This entry does not look into them.
- The checks are scripts outside the repository. `CodeIdentityTests` holds the cases they found.
- One person, building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 21:33:31 to 21:56:20 UTC−3 (00:33 to 00:56 on 4 November UTC).
