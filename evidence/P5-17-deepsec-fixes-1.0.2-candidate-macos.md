# P5-17: the 1.0.2 candidate in place, its install script on the same version, and a path with a line break

**Claim.** A 1.0.2 candidate (build 32) replaced 1.0.1 in place, in ask mode, with no restart. Its install script,
run again with 1.0.2 installed and no `--force`, checked the installed app's signature and kept it. A program whose
file name has a line break raised an event without its path, and `blackice pending` listed it, where 1.0.1 would have
rejected the whole pending reply. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi.

**Build.** Blackice.app 1.0.2, build 32, from 414b229, signed with the Developer ID Application of team M294LK997M,
notarized and stapled, `Blackice-1.0.2.zip` SHA-256 `7386b3d7e462baaa2e47178237004f9e6685783aa58843868e3973a941995576`.

**Configuration.** The owner's file (21 rules, ask mode, Claude Code answering).

**Run.** 6 November 2026, about 18:10 (UTC−3), from a Claude Code session on the Mac.

1. The install script with `BLACKICE_ZIP` and `--force`, then `blackice start` (Touch ID), over 1.0.1, build 31.
2. The install script again, with no `--force`.
3. Homebrew's `gh` 2.103.3 (ad hoc, cdhash `8fbec897bc4d2bf005bff3945dc800000ded2752`) copied to a file named
   `gh`, a line feed, then `evil`, in a temporary folder, running `api https://uploads.github.com/`, a host it had no
   approval for; `blackice pending` 1.5 s later.

**Result.**

1. `1.0.2/32 [activated enabled]`, ask mode, the 21 rules kept, no restart.
2. `✓ Blackice.app 1.0.2 is already in /Applications`, exit status 0, with no download.
3. `blackice pending` listed `ad hoc 8fbec897 → uploads.github.com:443` with its `blackice approve` line and no
   path. The event log has event `ev-53f84dd5` for that app and host, with no `app_path`.

Decided by: the extension and the install script.

**Limits.**

- The clock that counts sleep was not run across a real sleep; a unit test checks only that it is never behind the
  uptime.
- The escaping in `blackice report` was checked by a unit test, not with a line another program wrote to the log.
- The fault tests were not run on build 32.

**Date.** 6 November 2026.
