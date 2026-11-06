# P5-16: programs in folders macOS protects, dropped by 1.0.0 and asked about by 1.0.1

**Claim.** The published 1.0.0 dropped every connection of a program that runs from `~/Documents` or `~/Downloads`
as `unknown_identity`, in ask mode, with no event: macOS keeps the filter from reading those folders, so it could not
check the program's signature. The same `gh` binary connected from `/opt/homebrew`, `/private/tmp` and the home folder.
A 1.0.1 candidate (build 31) names such a program by the cdhash of the code the kernel loaded: a Developer ID binary
copied to `~/Documents` raised an event with that cdhash and its path, and Claude Code answered it. Phase 2, 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi.

**Builds.** Blackice.app 1.0.0, build 30, as published. Then Blackice.app 1.0.1, build 31, from 8cf9127, signed with
the Developer ID Application of team M294LK997M, notarized and stapled, `Blackice-1.0.1.zip` SHA-256
`91b81cfb2ebb0e2748aad6b70d7a5291f868105ed27833c64a01e8a2e6bcb2ce`, installed with the site's install script and
`BLACKICE_ZIP`, then `blackice start` (Touch ID).

**Configuration.** The owner's file (21 rules, ask mode, Claude Code answering). An approval from earlier that day
let ad hoc code with cdhash `8fbec897bc4d2bf005bff3945dc800000ded2752`, Homebrew's `gh` 2.103.3, reach
api.github.com.

**Run.** 6 November 2026, from a Claude Code session on the Mac.

1. 16:15–16:21 (UTC−3), on 1.0.0: deepsec ran its Codex, `@openai/codex` 0.166.0 (signing identifier `codex`, team
   2DC432GLL2), from `node_modules` in the repository's `.deepsec/` folder, under `~/Documents`. The owner's file has a
   rule for that identity to chatgpt.com.
2. On 1.0.0: `gh api zen` with the same `gh` copied to `/private/tmp/…`, to `~/Documents/…`, to `~/blackice-idtest` and
   to `~/Downloads/…`.
3. 16:51, on 1.0.1: an upgrade in place from 1.0.0 with `--force` and `blackice start`.
4. 16:52, on 1.0.1: `adb` from Android platform-tools 37.0.1 (signing identifier `adb`, team EQHXZ8M8AV), copied to
   `~/Documents/Github/Personal/blackice-idtest/adb`, ran `adb connect 192.0.2.1:5555`, a documentation address.

**Result.**

1. All 14 of deepsec's batches failed: Codex could not reach chatgpt.com ("error sending request"). The filter's log
   had no event for it, and 9,072 `flow drop unknown_identity app=unknown` lines in those six minutes.
2. `gh` from `/private/tmp`, the home folder and its Homebrew path printed its line; from `~/Documents` and
   `~/Downloads` it failed with `connect: bad file descriptor`. For the `~/Documents` copy the filter logged
   `flow drop unknown_identity` and raised no event.
3. `1.0.1/31 [activated enabled]`, no restart, the 21 rules kept.
4. The filter named `adb` `cdhash/0e4570869fc8b963a4527bd5bd9b8ef5afc79fe5`, the CDHash `codesign -dvvv` prints for
   that copy. Its connections to the adb server on 127.0.0.1 passed as loopback. The connection to 192.0.2.1 raised
   event `ev-cbffc51c` with `app_cdhash` and `app_path`
   `/Users/valen/Documents/Github/Personal/blackice-idtest/adb`, and Claude Code denied it 4.1 s later, so `adb` got
   `Bad file descriptor`.

Decided by: the extension (the identities and drops), Claude Code (the deny in step 4).

**Limits.**

- Only `~/Documents` and `~/Downloads` were tried. `~/Desktop`, iCloud Drive and removable and network volumes are the
  other places macOS asks permission for; they were not.
- A hard link to a file outside those folders is no test: the kernel names the file by its first path, and the
  signature is read from there. Step 4 used a copy.
- The fix was not run through deepsec's Codex itself: its folder had been moved out of `~/Documents` to finish the scan.

**Date.** 6 November 2026.
