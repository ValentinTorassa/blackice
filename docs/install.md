# Installing blackice

How to install blackice with the install script, with Homebrew or from a release package, check it, run it, remove it
and roll it back. The package is `Blackice-<version>.zip` plus `Blackice-<version>.zip.sha256`, as
`macos/scripts/package.sh` builds them, attached to each
[GitHub release](https://github.com/ValentinTorassa/blackice/releases). On 3 November 2026 the Homebrew section ran
from the published 0.1.0 release, as an upgrade over a build installed by hand
([P5-02](../evidence/P5-02-homebrew-upgrade-from-release-macos.md)), and the install script checked the release and
installed it into a temporary folder instead of `/Applications`
([P5-03](../evidence/P5-03-curl-install-script-sandbox-macos.md)). With 0.2.1, the uninstall steps and the script
installing into `/Applications` ran from the published release ([P5-04](../evidence/P5-04-install-start-faults-from-release-macos.md)).
With a 0.3.0 candidate, the same steps, the first `start` with its lists and fx set up by `start` ran from no
configuration and no fx ([P5-06](../evidence/P5-06-onboarding-from-zero-macos.md)).

You need a Mac with Apple silicon (the build is arm64 only), macOS 14 or later, and an admin account. blackice has
run on macOS 27.0.1 only. The commands below use 0.4.1 as the version.

## With the install script

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
```

The script ([`site/lib/install.sh`](../site/lib/install.sh)) downloads the zip and its checksum from the GitHub
release and runs the checks of step 1, except `stapler validate`, which needs Xcode's command line tools (`spctl`
checks the notarization as well). It also checks that the app and its extension are the version the script installs,
so an older release served under the new name does not pass. If a check fails, it stops before touching
`/Applications`. Otherwise it copies `Blackice.app` to `/Applications` and writes `~/.local/bin/blackice`, a small
script that runs `/Applications/Blackice.app/Contents/MacOS/blackice` (set `BLACKICE_BIN_DIR` for another folder). It
starts nothing. Run it as your user, without `sudo`.

It stops if blackice is installed with Homebrew, and if another version is in `/Applications`. To replace that one,
run it with `--force` (`curl -fsSL https://blackice-macos.vercel.app/install.sh | sh -s -- --force`), then see **To
upgrade** under Rollback. With `--force` it copies the new app into a hidden folder in `/Applications`, checks the
copy, and then swaps it with the installed one; if the swap fails, the installed copy is put back. It does not
replace a copy with a higher build number: see **To go back to an earlier version**. Then continue with step 3.

## With Homebrew

```console
$ brew trust --cask valentintorassa/tap/blackice
$ brew install --cask valentintorassa/tap/blackice
```

The first command tells Homebrew to trust this cask: Homebrew loads casks from taps other than its own only
after `brew trust`. The cask downloads the same zip from the GitHub release, checks it against the SHA-256 written in the cask, puts
`Blackice.app` in `/Applications` and adds a `blackice` command to Homebrew's `bin` folder: a small script that runs
`/Applications/Blackice.app/Contents/MacOS/blackice`, since a symbolic link does not work (see step 2). Homebrew does
not run the signature checks of step 1; to run them, use the commands there on `/Applications/Blackice.app`. Then
continue with step 3.

## 1. Download and check

Download both files into the same folder, then, in Terminal, in that folder:

```console
$ shasum -a 256 -c Blackice-0.4.1.zip.sha256
Blackice-0.4.1.zip: OK
$ ditto -x -k Blackice-0.4.1.zip .
$ codesign --verify --strict --deep --verbose=2 Blackice.app
$ codesign -dvv Blackice.app 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
Identifier=com.valentorassa.blackice
TeamIdentifier=M294LK997M
$ xcrun stapler validate Blackice.app
$ spctl --assess --type execute -vv Blackice.app
```

`codesign --verify` should say `valid on disk` and `satisfies its Designated Requirement`, `stapler validate` should
say the validate action worked, and `spctl` should say `accepted` with `source=Notarized Developer ID`. If any of them
fails, or the Team ID is not M294LK997M, stop: do not install that copy.

Double-clicking the zip in Finder unpacks it as well. `ditto` is the command-line way that keeps the signature intact.

## 2. Move it to /Applications

```console
$ ditto Blackice.app /Applications/Blackice.app
```

or drag it there in Finder. macOS activates system extensions only from an app in `/Applications`. To replace an
installed copy, Terminal needs App Management (System Settings → Privacy & Security → App Management).

The `blackice` command is the app's own executable. Call it by its full path, or put its folder on your `PATH`, for
example in `~/.zshrc`:

```sh
export PATH="/Applications/Blackice.app/Contents/MacOS:$PATH"
```

Use the folder on the `PATH`, or a script that runs the full path, rather than a symbolic link. The command checks
that it runs as the signed app, and started through a link it does not: on 3 November 2026, `blackice status` run
through a symbolic link said it needs Blackice.app signed with the Developer ID and exited with status 69, while the
full path, and a script that runs the full path, worked.

## 3. Write blackice.toml

`blackice start` reads `~/.config/blackice/blackice.toml` unless you pass `--config PATH`. If the file is not there,
`start` asks a few questions and writes it. You pick the answers from lists with the arrow keys:
- the mode;
- in ask mode, who answers: fx, Claude Code, Codex, or you;
- apps to trust, from the apps and system extensions running now (a VPN client's network extension, such as
  Tailscale's, is one). Each may reach any host, and "Another app" takes a path such as
  `/Applications/Slack.app` or a signing identifier.

If you pick an agent, `start` also sets it up, as `blackice agent connect` does for that agent (see "Let an agent
answer"). It stays in accept-all until the agent is installed, signed in and tested, and loads ask mode at the end, so
nothing waits on an answer before the agent can give it. If the agent cannot be set up, or you stop the setup with
Control-C, blackice stays on in accept-all, filtering nothing, as before that first start, and says so. Finish it
later with `blackice agent connect` and its name, or filter without an agent with `blackice mode ask` (you answer
with `blackice approve` and `deny`) or `blackice mode block-all`; until then `blackice status` says the same. `blackice init` asks the same questions without
starting anything. Or write the file yourself, starting in accept-all, which lets everything through and only logs:

```toml
mode = "accept-all"     # "accept-all", "ask" or "block-all"
timeout_seconds = 60    # in ask mode, no answer in time means deny

# Permanent rules: one app, by signing identifier (and Team ID unless it is Apple's), and its hosts.
[[allow]]
app = "com.apple.curl"
hosts = ["pypi.org"]
```

```console
$ mkdir -p ~/.config/blackice
$ blackice validate ~/.config/blackice/blackice.toml
```

For ask mode, add a `[[hook]]` that asks an agent and a rule that lets the agent reach its model provider, bound to its
signature; [`integrations/fx/README.md`](../integrations/fx/README.md) has the one for fx. Before turning ask mode on,
read the open problems in [`plan.md`](plan.md): with no rules for them, the Mac's own services wait and are dropped,
and Tailscale's DNS stops name lookups in ask and block-all.

## 4. Start the filter

```console
$ blackice start
$ blackice status
```

`start` asks for Touch ID (or your login password), activates the network extension and saves the configuration.
The first time, and after any deactivation, macOS holds the extension until you allow it. `start` opens System
Settings where macOS asks, and prints the steps for your macOS:

- macOS 26 and later: General → Login Items. Scroll to Blackice, click ⓘ next to it, turn on Network Extension and
  click Done.
- macOS 15: General → Login Items & Extensions. Under Extensions, click ⓘ next to Network Extensions, turn on Blackice
  and click Done.
- macOS 14: Privacy & Security. Under Security, click Allow where it says Blackice was blocked from loading.

Then macOS asks whether "Blackice" may filter network content: click Allow. `start` waits up to 10 minutes for all
this. The macOS 27 steps are from 27.0.1; the others follow Apple's layout of those versions. `blackice status` then
says which mode blackice is in, whether the daemon runs your hooks, and how many connections are waiting.

At the end, the first `start` asks whether to show blackice in the menu bar and open it at login (see "The menu bar"
under step 6).

## 5. Start the daemon

The daemon runs the hooks for connections that wait in ask mode. It runs as a LaunchAgent for your user and takes
its hooks from the configuration that `start` saved:

```console
$ blackice agent install
```

`blackice agent uninstall` removes it. Without a daemon, ask mode still pauses connections, and they are dropped
when their timeout passes.

### Let an agent answer

`blackice agent connect fx` sets fx up to answer the connections that wait in ask mode:

1. It finds fx and reads its signature. If fx is not installed, it shows fx's installer
   (`curl -fsSL https://fx.sh/setup.sh | bash`) and runs it if you say yes.
2. It gives fx a home of its own, `~/.config/blackice/agent`, for its sign-in and rules. The blackice skill is not
   put there: the hook names it, and the daemon writes it from blackice into each event's directory. If fx has
   no sign-in there, it runs `fx login vercel`: press Enter to open the page fx names, and allow access. If the
   sign-in fails, it offers it again. It sets fx's rules there so that fx can read files and nothing else: no
   shell, no edits, no web.
3. It runs the hook once on a sample connection and checks that fx's last line is an answer, `deny` or
   `approve 10m`. That answer is only read, so nothing is let through. AI Gateway needs a card on file for the
   Vercel team fx signed in with; without one, the test fails with HTTP 403 `customer_verification_required`.
   With no credits left on that team, it fails with HTTP 502 `insufficient_funds`; add credits on the team's AI
   Gateway page in the Vercel dashboard.
4. Only then does it add to `blackice.toml` a rule that lets fx reach its model (Vercel's AI Gateway) in every mode,
   and the hook, and raise `timeout_seconds` to at least 60. The hook starts fx directly, and only when fx's
   signature names the signing identifier and Team ID read in step 1. A hook from 0.3 that runs the skill with
   `run` is replaced.
5. Unless the file is in ask mode already, it asks whether to switch. It loads the file (Touch ID) and starts the
   daemon.

In ask or block-all it switches to accept-all while fx is set up (Touch ID), since fx's own connections would wait
until its rule is loaded, and the last step loads your file again. If the setup stops before that step, because a
step failed or you pressed Control-C, it switches back to the mode it was in (Touch ID). Control-C while fx signs in
goes to fx, and the setup stops once fx has quit.
[`integrations/fx/README.md`](../integrations/fx/README.md) has the same steps by hand.

`blackice agent connect claude-code` does the same for Claude Code. Its home is a Claude Code configuration
directory of its own, `~/.config/blackice/agent/.claude`, signed in with `claude auth login`; the sign-in stays in
the login keychain, apart from yours. Its hook gives it one tool, reading the event, and keeps the event off its
stdin (`stdin = "none"`), since `claude -p` would add it to the prompt. Its rule covers `api.anthropic.com` and
`platform.claude.com`. [`integrations/claude-code/README.md`](../integrations/claude-code/README.md) has the details.

`blackice agent connect codex` does the same for Codex, signed in with a ChatGPT plan. Install it first (`brew
install --cask codex`). Its home is a `CODEX_HOME` of its own, `~/.config/blackice/agent/.codex`, signed in with
`codex login`. Its hook runs `codex exec` with commands that can read only the event's directory and the system's
own files, write nothing and reach no network, and keeps the event off its stdin. Its rule covers `chatgpt.com` and
`auth.openai.com`. [`integrations/codex/README.md`](../integrations/codex/README.md) has the details.

Each agent decides with a small model, since a decision is a short read and a two-line answer: fx with Claude
Haiku 5.5 through AI Gateway (`anthropic/claude-haiku-5.5`, billed to the Vercel team fx signed in with), Claude Code
with `haiku` (counted against its subscription), Codex with `gpt-6-luna` (counted against the ChatGPT plan).
`--model NAME` writes another into the hook, such as
`blackice agent connect claude-code --model sonnet`; running `agent connect` again with another model replaces the
hook's. The agents approve clearly ordinary developer and vendor traffic for 8 to 24 hours and anything less plain
for 10 minutes to an hour.

One agent answers at a time. Connecting one replaces the hook of another (with two, the first answer would win)
and says so.

## 6. Use it

- `blackice mode ask`, `blackice mode block-all`, `blackice mode accept-all`: change the mode (Touch ID each time).
- `blackice pending`: the connections waiting for an answer, the current approvals, and the denials of the last
  10 minutes, whose connections are dropped without asking.
- `blackice approve --app ID --host HOST --for 1h` and `blackice deny …`: answer as a person (Touch ID).
- `blackice report [--last 1h]`: the filter's log summed up, with drops by reason and app, and in accept-all what
  ask mode would have asked about.
- The daemon's event log is `~/Library/Logs/blackice/events.jsonl`. The filter logs one line per decision to
  unified logging:

  ```console
  $ /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.valentorassa.blackice.filter"'
  ```

  Each line shows the verdict, the reason and the app in the clear (`flow drop timeout
  app=ABCDE12345/com.example.tool`, `apple/…` for Apple's own code, `cdhash/…` for ad hoc code); the host and
  the rest show as `<private>`.
- A connection blackice drops fails in the app with "Bad file descriptor" (EBADF) when it connects: `ssh` and the
  Tailscale CLI print `connect: Bad file descriptor`. That is blackice, not the network or a bug in the app, and the
  filter's log above shows why (`flow drop` and the reason). macOS gives a filter no way to refuse with another
  error.

After changing `blackice.toml`, run `blackice start` again to load it (Touch ID).

### The menu bar

Blackice.app runs in the menu bar when you open it from Finder or Spotlight, and with `blackice menu`, which runs until
you quit it or close the terminal. `blackice menu --login on` opens it now and at each login, where System Settings →
General → Login Items lists it as Blackice; `blackice menu --login off` stops that. Opening at login works only for the
signed Blackice.app in `/Applications`. `blackice` with no arguments in a terminal still prints the usage: the menu
starts only when LaunchServices opens the app, with no arguments, launchd as its parent and no terminal.

The mark is full in ask and block-all, and dimmed when blackice is off, in accept-all or not reachable. When
connections wait, their number is next to it. The menu has:

- the mode the filter decides in, or why blackice is off or not reachable, and the version. As `blackice status`
  does, it says when the filter did not take the saved settings and when an upgrade needs `blackice start`;
- each connection that waits, as app → host:port with the seconds left, and in its submenu Allow for 10 Minutes,
  Allow for 1 Hour and Deny: the same as `blackice approve --for` and `blackice deny`, with Touch ID;
- the last verdicts from the event log, with whether a hook or a person answered, and for an hour a warning when the
  daemon refused a hook program whose signature did not match;
- Mode, to switch between accept-all, ask and block-all, with Touch ID, as `blackice mode` does, while the filter
  answers;
- the hooks in the configuration and whether the daemon runs them;
- Open blackice.toml, Show Event Log in Finder, Documentation, Open at Login, and Quit Menu.

Quitting the menu leaves the filter and the daemon running. Starting and stopping blackice, rules, agents and the
daemon stay in the CLI. The menu has not run as the signed app yet: Touch ID from the menu, Open at Login and its reads
of the filter are untested on a Mac.

## Uninstall

```console
$ blackice menu --login off
$ blackice agent uninstall
$ blackice stop
$ rm -rf /Applications/Blackice.app
```

If blackice is in the menu bar, choose Quit Menu in its menu first. If you used the install script, also remove
`~/.local/bin/blackice`. With Homebrew, run the first three commands, then
`brew uninstall --cask blackice` instead of `rm`. Homebrew cannot deactivate the extension, so run `blackice stop`
first. `brew uninstall --zap --cask blackice` also removes `~/Library/Logs/blackice`, but not your settings in
`~/.config/blackice`.

`stop` asks for Touch ID, removes blackice's filter configuration and deactivates the extension. It needs no
network. Moving the app to the Trash in Finder works as well as `rm`; either needs App Management for Terminal. `systemextensionsctl list` may show the extension as waiting to uninstall until the next restart. To also
remove your settings and logs: `rm -rf ~/.config/blackice ~/Library/Logs/blackice`.

## Rollback

**If the network misbehaves** in ask or block-all, switch back first, then look:

```console
$ blackice mode accept-all
```

In accept-all the filter lets every connection through. A restart alone does not turn the filter off: macOS keeps a
saved content filter across restarts.

**If `blackice` itself fails**, run it by its full path to see its message
(`/Applications/Blackice.app/Contents/MacOS/blackice stop`). If `stop` still fails:

1. System Settings → Network → Filters (near VPN): remove blackice's content filter.
2. System Settings → General → Login Items: click ⓘ next to Blackice and turn off Network Extension (on macOS 15,
   Login Items & Extensions → Network Extensions).
3. `launchctl bootout gui/$(id -u)/com.valentorassa.blackice.daemon`, if the daemon is still loaded.
4. Move `/Applications/Blackice.app` to the Trash and restart. Then `systemextensionsctl list` should no longer show
   `com.valentorassa.blackice.filter` as `activated enabled`.

These labels are from macOS 27.0.1 and from memory; [`phase-0.md`](phase-0.md) has the same steps from the first
runs.

**To go back to an earlier version**: macOS replaces an installed extension only with the same or a higher
`CFBundleVersion`, so an older package does not install over a newer one. Uninstall (above), restart if
`systemextensionsctl list` shows the extension waiting to uninstall, then install the older package from step 1 and
allow the extension again in System Settings.

**To upgrade**, check the new package as in step 1, put its `Blackice.app` in `/Applications` over the old one (with
Homebrew, `brew upgrade --cask blackice`; with the install script, run it with `--force`) and run `blackice start`
right away. macOS replaces the running extension with the one with the higher build number, and `start` checks that
the new one answers over XPC. If it does not, `start` says so and exits with status 75: restart the Mac, then run
`blackice start` again. The daemon needs nothing: when the old extension stops, the daemon's connection ends, it
exits, and launchd starts it again from the new app.

If blackice is in the menu bar, quit it from its menu and open Blackice.app again after `start`, so that it runs the
new binary and reaches the new extension.

Upgrading to 0.3.2 or an earlier version, restart the Mac after `start` even when it succeeds. Up to 0.3.2 every
build's extension listened on the same XPC service name. On macOS 27.0.1 the replaced build's process still held that
name for up to 5 s after macOS started the new build, launchd refused the name to the new one, and the new extension
kept filtering but could not be reached until the Mac restarted: the daemon, `pending`, `approve` and `deny` failed,
and ask mode dropped everything it paused. That happened in about every other upgrade. After 0.3.2 each build has its
own name. Until `start` runs, the new `blackice` then cannot reach the old extension, so hooks' answers fail and ask
mode denies what waits for them; `status`, `pending`, `approve` and `deny` say to run `blackice start` to finish the
upgrade. Not yet run on a Mac.
