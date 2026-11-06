# P5-12: from no blackice to ask mode with the published 0.4.6, and the menu bar opened by start

**Claim.** On a Mac with 0.4.5 uninstalled by `docs/install.md`'s steps and no configuration, the site's one-liner
installed the published 0.4.6 in 2 s, and one `blackice start` took it to ask mode with Claude Code answering in about
54 s: the lists, Touch ID, the extension allowed in System Settings, Claude Code signed in and tested (it approved the
sample in 3 s), its rule and hook, and the daemon. `start` opened the menu bar app by itself, 6 s before the daemon
was installed and before the question about opening at login, which is what 0.4.6 changed. Phases 4 and 5.

**Platform.** MacBook Air (Mac16,12), macOS 27.0.1 (26A434), arm64, System Integrity Protection on. Wi-Fi, Tailscale
running with its DNS on.

**Build.** Blackice.app 0.4.6, build 27, from 949042a (release v0.4.6), signed with the Developer ID Application of
team M294LK997M, notarized and stapled. `Blackice-0.4.6.zip` SHA-256
`2d9d8a73c90d3cd21380d07bdbe4bb3c4df9341e42e2efb09682597ed3a0594c`, checked again after downloading it from the
release. Claude Code 2.1.318 (Homebrew cask), already signed in to the account the agent uses.

**Configuration.** None at the start: the owner's `~/.config/blackice` was moved aside for the run and put back
after. The first `start` wrote this one (comments left out):

```toml
mode = "ask"
timeout_seconds = 60

[[allow]]
app = "com.anthropic.claude-code"
team = "Q6L2SF6YDW"
hosts = ["api.anthropic.com", "platform.claude.com"]

[[hook]]
on = "connection"
program = "/opt/homebrew/bin/claude"
app = "com.anthropic.claude-code"
team = "Q6L2SF6YDW"
args = ["-p", "--restricted", "--safe-mode", "--tools", "Read", "--strict-mcp-config", "--no-session-persistence", "--permission-prompts", "none", "--model", "haiku", "--max-turns", "3", "--output-format", "text", "--system-prompt-file", "instructions.md", "Decide the pending blackice connection in event.json."]
env = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "CLAUDE_CONFIG_DIR=/Users/valen/.config/blackice/agent/.claude"]
stdin = "none"
instructions = "claude-code"
```

**Run.** 6 November 2026, from a Claude Code session on the Mac, with the owner at the keyboard.

1. 14:32 UTC: the uninstall steps of `docs/install.md` for 0.4.5: Quit Menu, `blackice menu --login off`, `blackice
   agent uninstall`, `blackice stop` (Touch ID), and the app and `~/.local/bin/blackice` moved to the Trash.
   `systemextensionsctl list` showed 0.4.5/26 "terminated waiting to uninstall on reboot". No restart.
2. 14:34: `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh`.
3. 14:35:01: `blackice start` in a Terminal window, recorded with `script`. The owner picked ask mode, Claude Code
   and no apps, gave Touch ID twice, turned on the extension in System Settings and answered yes to opening at login.
4. After the run the owner's configuration was put back, and the owner later recorded the same from-zero run on
   video; that recording is not in the repo.

**Result.**

The install script, whole:

```text
Downloading https://github.com/ValentinTorassa/blackice/releases/download/v0.4.6/Blackice-0.4.6.zip
✓ Checked the checksum, the signature (team M294LK997M), the notarization and the version: 0.4.6, build 27
✓ Blackice.app 0.4.6 is in /Applications
✓ Wrote /Users/valen/.local/bin/blackice

Next: blackice start
```

The first `start`, with the lists' redraws left out:

```text
1 · Pick a mode
  How should blackice treat new connections? ask
  Who answers the connections that wait? Claude Code
  Which apps may connect anywhere, in every mode? none
  ✓ Saved ~/.config/blackice/blackice.toml: ask mode, no rules
2 · Confirm with Touch ID
  ✓ Confirmed
3 · Allow the network extension
  System Settings is open at General › Login Items:
  Waiting for you (up to 10 minutes)…
  ✓ Allowed
  macOS now asks whether Blackice may filter network content: click Allow.
  ✓ blackice is on in accept-all mode until claude-code is set up
4 · Connect claude-code
  ✓ /opt/homebrew/bin/claude (com.anthropic.claude-code, team Q6L2SF6YDW)
  ✓ signed in, in its own home (~/.config/blackice/agent)
  ✓ reads the event only: no shell, no web, no MCP servers
  Testing with haiku on a sample connection…
  ✓ approved it in 3 s
  ✓ rule: claude-code may reach api.anthropic.com and platform.claude.com in every mode
  ✓ hook: claude-code answers each connection that waits
  ✓ saved ~/.config/blackice/blackice.toml
Touch ID to start filtering in ask mode, 1 rule, 1 hook, 60 s to answer…
✓ blackice is on in ask mode, Claude Code answers
✓ The daemon runs your hooks, now and at each login (logs in ~/Library/Logs/blackice)
Open blackice in the menu bar at each login? [Y/n]: Y
✓ blackice is in the menu bar, and opens there at each login
```

The menu bar app and the daemon, from `ps -o lstart=` (local time, UTC−3):

```text
Fri Nov  6 11:35:36 2026      /Applications/Blackice.app/Contents/MacOS/blackice
Fri Nov  6 11:35:42 2026      /Applications/Blackice.app/Contents/MacOS/blackice daemon
```

The menu bar app started when the first `start` turned the filter on in accept-all, before the agent was connected
and before the question about opening at login, so `start` opened it and not the login item. `systemextensionsctl
list` then showed `com.valentorassa.blackice.filter (0.4.6/27) [activated enabled]`, and `blackice status` showed ask
mode with Claude Code answering.

**Limits.**

- With one rule, 29 apps and hosts were waiting a minute after the run: picking no apps leaves the browsers, Slack
  and the VPN client to the agent, one question each.
- Putting the owner's file back and running `blackice start` left blackice in accept-all, twice: the switch to
  accept-all made while another file was loaded counted as the owner's own (see P5-11). `blackice mode ask` put it
  back. Not fixed yet.
- Claude Code was already signed in, so the sign-in itself did not run; fx, Codex and opencode were not picked.
- Not covered: Homebrew, macOS 14 and 15, and an Intel Mac.

**Date.** 6 November 2026.
