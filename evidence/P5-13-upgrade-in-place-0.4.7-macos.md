# P5-13: an upgrade in place from 0.4.6 to 0.4.7, in ask mode, with no restart

**Claim.** On a Mac filtering in ask mode with the published 0.4.6, the install script with `--force` and one
`blackice start` replaced it with the published 0.4.7, with no restart. macOS swapped the extension (build 27 for
build 28) in 0.27 s, and 0.35 s after `start` asked for it the new extension had the file's configuration; it had
started in ask mode with the owner's 21 rules and hook, saved by the old one, before `start` loaded them again; the daemon and the menu bar app restarted by themselves; and Claude Code went on answering
under 0.4.7's instructions. The old extension dropped 52 connections it held as it stopped. Phase 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, Tailscale
running with its DNS on. Data volume 69% full.

**Build.** From Blackice.app 0.4.6, build 27 (release v0.4.6, installed by the site's script in P5-12), to 0.4.7,
build 28, from 6dceb45 (release v0.4.7), signed with the Developer ID Application of team M294LK997M, notarized and
stapled. `Blackice-0.4.7.zip` SHA-256 `5090cd9afcd417d413072aab8070913092df9819435d8a600aa6ad1681a52846`. Claude Code
2.1.318 (Homebrew cask) as the answerer, fx also connected.

**Configuration.** The owner's own `~/.config/blackice/blackice.toml`, unchanged by the upgrade: `mode = "ask"`,
`timeout_seconds = 60`, 21 `[[allow]]` rules, the Claude Code hook and `answers = "claude-code"` in `[agent]` (see
P5-10). The filter was in ask mode, switched there with `blackice mode ask --agent claude-code` after the release was
signed.

**Run.** 6 November 2026, about 12:13 local time (UTC−3), from a Claude Code session on the Mac, with the owner at the
keyboard for Touch ID. First `brew upgrade --cask blackice && blackice start`, which stopped at once: "Error: Cask
'blackice' is not installed", since this Mac had the script's install, not the cask's. Then:

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh -s -- --force && blackice start
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.4.7/Blackice-0.4.7.zip
✓ Checked the checksum, the signature (team M294LK997M), the notarization and the version: 0.4.7, build 28
Replacing the installed /Applications/Blackice.app
✓ Blackice.app 0.4.7 is in /Applications

Next: blackice start (if it exits with 75, restart the Mac and run it again)
Touch ID to start filtering in ask mode, 21 rules, 1 hook, 60 s to answer…
✓ blackice is on in ask mode, Claude Code answers
```

**Result.**

1. The menu bar app restarted at 12:13:30 (a new `Blackice.app/Contents/MacOS/blackice`, pid 29670), as `docs/install.md`
   says an open one does.
2. At 12:13:33.484 `start` asked sysextd to activate the extension, and sysextd found build 27 to replace
   ("activateDecision found entry to replace: … CFBundleShortVersionString: "0.4.6", CFBundleVersion: "27"").
3. The old extension (pid 15980) stopped at 12:13:33.533, after dropping the 52 connections it held with the reason
   `provider_stopped`: 51 of Claude Code and 1 of an ad hoc program.
4. The new extension (pid 29676) started at 12:13:33.804 with the configuration the old one had saved: "started mode
   ask, 21 allow rules, 1 hook, generation 7", and 99 app identities restored. So between the two there was no
   accept-all and no empty configuration.
5. The daemon, which exits when the extension goes away, was restarted by launchd (pid 29675) and registered with the
   new extension at 12:13:33.822. `start` installed the file's configuration again, generation 8, at 12:13:33.836.
6. `systemextensionsctl list` then showed 0.4.7/28 `[activated enabled]` and 0.4.6/27 `[terminated waiting to
   uninstall on reboot]`, with the older builds of the earlier upgrades.
7. In the 11 minutes after, Claude Code decided 31 events with 0.4.7's instructions: 21 approved (among them a Homebrew
   `node` to registry.npmjs.org and `uv` to pypi.org and files.pythonhosted.org), 9 denied and 1 cancelled when a
   later `start` reloaded the file.

Decided by: sysextd (the replacement), the extension (its saved configuration, the dropped connections), launchd (the
daemon and the menu bar app) and `start`.

**Log lines.** From the unified log (`log show`, subsystem `com.valentorassa.blackice.filter` and sysextd), local time:

```text
2026-11-06 12:13:33.484 Df sysextd[490:466591] [com.apple.sx:XPC] client activation request for com.valentorassa.blackice.filter
2026-11-06 12:13:33.494 Df sysextd[490:466591] [com.apple.sx:Upgrade] activateExtension wants to replace com.valentorassa.blackice.filter
2026-11-06 12:13:33.532 Df com.valentorassa.blackice.filter[15980:46a3c2] [com.valentorassa.blackice.filter:flows] flow drop provider_stopped app=Q6L2SF6YDW/com.anthropic.claude-code <private>
2026-11-06 12:13:33.533 Df com.valentorassa.blackice.filter[15980:46a3c2] [com.valentorassa.blackice.filter:control] control stopped reason_1
2026-11-06 12:13:33.804 Df com.valentorassa.blackice.filter[29676:46f456] [com.valentorassa.blackice.filter:control] control started mode ask, 21 allow rules, 1 hook, generation 7
2026-11-06 12:13:33.822 Df com.valentorassa.blackice.filter[29676:46f457] [com.valentorassa.blackice.filter:control] control xpc daemon_registered 7
2026-11-06 12:13:33.836 Df com.valentorassa.blackice.filter[29676:46f457] [com.valentorassa.blackice.filter:control] control configuration_installed mode ask, 21 allow rules, 1 hook, generation 8
```

**Limits.**

- The 52 dropped connections were held by the filter, waiting for a TLS ClientHello or for an answer. Claude Code opens
  connections it may not use for minutes (in the hour before, the report counted 768 of its connections dropped for
  sending nothing for 2 minutes), so these were most likely idle ones; the Claude Code session that ran the upgrade
  kept working. This run does not show which kind they were.
- Nothing shows what macOS did with new connections in the 0.27 s with no extension running.
- `brew upgrade --cask blackice` works only for a cask install, and the error says so; `docs/install.md` now says which
  command fits which install.
- Not covered: an upgrade with connections waiting for an answer, an upgrade in block-all, the cask's upgrade, and
  macOS 14 and 15.

**Date.** 6 November 2026.
