# P5-03: the curl install script checks the published 0.1.0 release and installs it into a temporary folder (macOS)

**Claim.** On the Mac that has blackice 0.1.0 installed with Homebrew, `curl -fsSL …/install.sh | sh` stopped at the
Homebrew check and changed nothing. A copy of the same script, with its destination moved from `/Applications` to a
temporary folder and its Homebrew check turned off, downloaded the v0.1.0 release, matched its checksum, verified
the app's signature (team M294LK997M, Developer ID Application) and Gatekeeper's assessment (notarized), copied the
app, and wrote the `blackice` command, which ran the copy. A second run found the same version and only kept the
command; with an older version in place it refused without `--force` and replaced the app with it. This bears on
phase 5's check, an install from the published package. It does not cover a copy into the real `/Applications`, or
starting the extension from a copy the script installed.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection enabled. `/bin/sh`
is GNU bash 3.2.57; curl 8.7.1.

**Build.** The script `site/lib/install.sh` from commit 4431284 (PR #21), served by that commit's Vercel preview
deployment at `/install.sh`, byte for byte the file in the repository. It installed Blackice.app 0.1.0 (build 5)
from the v0.1.0 release (`Blackice-0.1.0.zip`, SHA-256
`f7d5280aba612ad8d7894adedac4931b9322ab6d5f2b0e84e56f574d48482c57`), the same package as P5-02. Before the run,
that release was installed with Homebrew in `/Applications` and active.

**Configuration.** None: the script does not read or write `blackice.toml`, and nothing was started.

**Run.** Over SSH, with no person at the Mac:
1. The one-liner as published, from the preview deployment: `curl -fsSL <preview>/install.sh | sh`. Then the
   modification time of `/Applications/Blackice.app` and whether `~/.local/bin/blackice` existed.
2. The same download piped through `sed`, which changed two lines: `APP=` to `<tmp>/Applications/Blackice.app`, and
   the Homebrew check's `Caskroom/blackice` to a name that does not exist. Run with `BLACKICE_BIN_DIR=<tmp>/bin`.
   Then the command it wrote, `codesign --verify` and `spctl --assess` on the copy.
3. Step 2 again.
4. `plutil` set the copy's `CFBundleShortVersionString` to 0.0.9; step 2 again, then with `sh -s -- --force`.
5. The temporary folder was removed.

**Result.**

| Step | What happened | Decided by |
|---|---|---|
| One-liner | Exit 1 with the Homebrew message, before any download. `/Applications/Blackice.app` unchanged; no `~/.local/bin/blackice`. | script |
| Download | Both files over HTTPS from the release; the `.sha256` parsed as one line for the zip; `shasum` matched. | script |
| Checks | `codesign --verify --strict --deep` passed; identifier, team and leaf certificate matched; `spctl`: `accepted`, `source=Notarized Developer ID`, origin of team M294LK997M. | macOS, script |
| Install | `ditto` copied the app; the command is the cask's wrapper and ran the copy's `help`. The copy verified again after the copy. | script |
| Second run | Same version found: no download, exit 0. | script |
| Older version | Without `--force`: exit 1 and the command to replace it. With `--force`: removed, downloaded, checked, copied; the copy is 0.1.0 and verifies. | script |

**Log lines.** The run's output, with `<tmp>` for `/tmp/bi-curl.3c0fNF` and `~` for the home folder:

```
== 1. real one-liner (Homebrew install present)
2026-11-03 16:48:49 -03
blackice install: blackice is installed with Homebrew; to upgrade it, run `brew upgrade --cask blackice`
exit=1
/Applications/Blackice.app untouched
ls: ~/.local/bin/blackice: No such file or directory
== 2a. full install into the sandbox
2026-11-03 16:49:10 -03
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.1.0/Blackice-0.1.0.zip.sha256
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.1.0/Blackice-0.1.0.zip
  SHA-256: f7d5280aba612ad8d7894adedac4931b9322ab6d5f2b0e84e56f574d48482c57, as Blackice-0.1.0.zip.sha256 says
Checking Blackice.app
  signature: valid, and satisfies its Designated Requirement
  signed by: Developer ID Application, team M294LK997M
  Gatekeeper: accepted, source=Notarized Developer ID
Blackice.app 0.1.0 is in /Applications.
Wrote <tmp>/bin/blackice, which runs <tmp>/Applications/Blackice.app/Contents/MacOS/blackice.
exit=0
--- wrapper:
#!/bin/sh
exec <tmp>/Applications/Blackice.app/Contents/MacOS/blackice "$@"
--- wrapper runs the app:
usage: blackice <command> [options]
--- installed copy, checked again:
codesign ok
<tmp>/Applications/Blackice.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Valentin Torassa Colombero (M294LK997M)
== 2b. run again, same version
Blackice.app 0.1.0 is already in /Applications.
exit=0
== 2c. pretend 0.0.9 is installed, without and with --force
blackice install: <tmp>/Applications/Blackice.app 0.0.9 is already there. To replace it with 0.1.0, run `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh -s -- --force`, then `blackice start`, and restart the Mac.
exit=1
  SHA-256: f7d5280aba612ad8d7894adedac4931b9322ab6d5f2b0e84e56f574d48482c57, as Blackice-0.1.0.zip.sha256 says
  Gatekeeper: accepted, source=Notarized Developer ID
Removing the installed <tmp>/Applications/Blackice.app
Blackice.app 0.1.0 is in /Applications.
You replaced an installed copy: run `blackice start`, then restart the Mac, then run
0.1.0
codesign ok after --force
```

The PATH hint and the next steps after steps 2 and 3, and all but the first line of `help`, are left out; the
`exit=1` of step 1 printed before the message, which went to stderr. No `blackice-install.*` folder was left
in `$TMPDIR` after the runs.

**Recording.** None.

**Limits.**
- **Not into `/Applications`.** The Mac already had the Homebrew install, so the copy went to a temporary folder,
  and the Homebrew check was turned off for it. The script's messages still say `/Applications`, since they are
  fixed text. Writing to the real `/Applications`, and App Management when replacing a copy there, were not run.
- **Nothing started.** No `blackice start`, extension approval or daemon from a copy the script installed; P5-02
  covers those with the same package installed by Homebrew.
- **Failures not provoked on the Mac.** A bad checksum, a wrong signature, Gatekeeper rejecting the app, Intel and
  older macOS were tested with the macOS tools stubbed, on Linux; that is not evidence of this kind.
- From the preview deployment, not the production site; the file is the same.
- One run, by the people building blackice, on one Mac. Not an independent test.

**Date.** 2026-11-03, 16:48:49 to 16:50 UTC−3 (19:48 to 19:50 UTC).
