# Installing blackice

Install blackice, start it, answer what waits, let an agent answer, upgrade and uninstall.

blackice 1.0.6 has run on one Mac, with macOS 27.0.1; macOS 14 and 15 are not tested yet. A `blackice.toml` that
works in 1.0 keeps working in every 1.x.

You need a Mac with Apple silicon, macOS 14.4 or later, and an admin account.

## With the install script

```console
$ curl -fsSL https://blackice-macos.vercel.app/install.sh | sh
```

The [script](../site/lib/install.sh) downloads the zip from the GitHub release and checks it: its SHA-256 against the
one the script pins and the release's `.sha256` file, then the signature (Developer ID, Team ID M294LK997M), the
notarization and the version. Then it copies Blackice.app to `/Applications` and writes `~/.local/bin/blackice`
(`BLACKICE_BIN_DIR` picks another folder). It starts nothing. Run it as your user, without `sudo`. To replace another
installed version, add `--force`: `curl -fsSL https://blackice-macos.vercel.app/install.sh | sh -s -- --force`.

The script's checks hold only if the script is the real one, and the site serves it: whoever controls the site
controls what runs. To read it before it runs:

```console
$ curl -fsSL -o install.sh https://blackice-macos.vercel.app/install.sh
$ less install.sh
$ sh install.sh
```

The site serves the copy on the repository's `main` branch, so this prints nothing:
`curl -fsSL https://raw.githubusercontent.com/ValentinTorassa/blackice/main/site/lib/install.sh | diff - install.sh`.
To skip the site, run the copy at the release's tag on GitHub instead:

```console
$ curl -fsSL https://raw.githubusercontent.com/ValentinTorassa/blackice/v1.0.6/site/lib/install.sh | sh
```

That one trusts GitHub and whoever can push the tag. The steps [by hand](#by-hand) trust neither the site nor the
script: you check Apple's signature, the notarization and the Team ID yourself.

## With Homebrew

```console
$ brew trust --cask valentintorassa/tap/blackice
$ brew install --cask valentintorassa/tap/blackice
```

Homebrew loads a cask from another tap only after `brew trust`. It checks the zip's SHA-256, not its signature: to check
that, run the `codesign` and `spctl` lines below on `/Applications/Blackice.app`.

## By hand

Download `Blackice-1.0.6.zip` and `Blackice-1.0.6.zip.sha256` from the
[GitHub release](https://github.com/ValentinTorassa/blackice/releases/tag/v1.0.6). In that folder:

```console
$ shasum -a 256 -c Blackice-1.0.6.zip.sha256
Blackice-1.0.6.zip: OK
$ ditto -x -k Blackice-1.0.6.zip .
$ codesign --verify --strict --deep --verbose=2 Blackice.app
$ codesign -dvv Blackice.app 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
Identifier=com.valentorassa.blackice
TeamIdentifier=M294LK997M
$ xcrun stapler validate Blackice.app
$ spctl --assess --type execute -vv Blackice.app
$ ditto Blackice.app /Applications/Blackice.app
```

`codesign --verify` should say `valid on disk` and `satisfies its Designated Requirement`, `stapler` that the validate
action worked, and `spctl` `accepted` with `source=Notarized Developer ID`. If one fails, or the Team ID is not
M294LK997M, do not install that copy. macOS activates the extension only from `/Applications`.

Then put the command's folder on your `PATH`, for example in `~/.zshrc`. Not a symbolic link: started through one,
`blackice` refuses to run (exit status 69).

```sh
export PATH="/Applications/Blackice.app/Contents/MacOS:$PATH"
```

The `.sha256` file comes from the same release as the zip, so on its own it only catches a broken download. The
signature, the Team ID and the notarization show that the app is blackice's. The SHA-256 should also be the one on the
`SHA256=` line of the [install script](https://github.com/ValentinTorassa/blackice/blob/v1.0.6/site/lib/install.sh)
at the release's tag (releases before 1.0.0 have no such line).

## Start

```console
$ blackice start
```

The first time, `start` asks a few questions and writes `~/.config/blackice/blackice.toml`: the mode, who answers in
ask mode (fx, Claude Code or you), and, unless you pick accept-all, which apps may connect anywhere. That list starts
with the VPN tunnels macOS has activated and the common apps running now (browsers, chat and video-call apps, named by
their signature), ticked, then the other network extensions, such as a VPN's split tunneling, which carries other
apps' connections, and the other apps running now, unticked. A picked app's rule covers its helpers signed by the same
team, since a browser's or a chat app's connections come from its helper. Leave a VPN tunnel, such as Tailscale's,
ticked, or names stop resolving in ask and block-all. Codex and opencode answer once you run `blackice agent connect
codex` or `opencode`.

Then `start` asks for Touch ID (or your login password), and macOS asks you to allow the extension. `start` opens System
Settings and prints the steps:

- macOS 26 and later: General → Login Items. Click ⓘ next to Blackice, turn on Network Extension, click Done.
- macOS 15: General → Login Items & Extensions. Under Extensions, click ⓘ next to Network Extensions, turn on Blackice,
  click Done.
- macOS 14: Privacy & Security. Under Security, click Allow where it says Blackice was blocked from loading.

Then click Allow when macOS asks whether "Blackice" may filter network content. If you picked an agent, `start` then
sets it up, as [`agent connect`](#let-an-agent-answer) does, and turns on ask mode only once the agent works; if the
setup fails, blackice stays in accept-all. At the end it offers to open blackice in the menu bar at each login.

After editing `blackice.toml`, run `blackice start` again to load it (Touch ID).

## Use it

- `blackice status`: the mode, who answers and what waits.
- `blackice mode ask`, `blackice mode block-all`, `blackice mode accept-all`: switch the mode (Touch ID).
- `blackice pending`: what waits, each with the `blackice approve` line that lets it through, then the approvals and the
  denials of the last 10 minutes.
- `blackice approve --app ID --host HOST --for 1h` and `blackice deny --app ID --host HOST`: answer (Touch ID).
- `blackice report`: what the filter dropped in the last hour, by reason and app. In accept-all it also lists what ask
  mode would have held: give those apps rules before you switch to ask.

### The menu bar

`blackice start` shows blackice in the menu bar, as do `blackice menu` and opening Blackice.app. `blackice menu
--login on` also opens it at each login, and `--login off` stops that. The mark is full in ask and block-all and dimmed otherwise, with the number of
connections that wait. From the menu you can allow a waiting connection for 10 minutes or an hour, deny it, switch the
mode and who answers, and stop filtering, each with Touch ID. Quit Menu leaves the filter running.

### "Bad file descriptor"

A connection blackice drops fails in the app with "Bad file descriptor" (EBADF): `ssh` and the Tailscale CLI print
`connect: Bad file descriptor`. That is blackice, not the network or a bug in the app; macOS gives a filter no other way
to refuse. The filter's log says why, with a `flow drop` line naming the reason and the app (the host shows as
`<private>`):

```console
$ /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.valentorassa.blackice.filter"'
```

## Let an agent answer

```console
$ blackice agent connect claude-code
```

`agent connect` offers to install the agent (install Codex yourself first), gives it a home of its own under
`~/.config/blackice/agent`, signs it in there and tests it on a sample connection. Only then does it add to
`blackice.toml` the agent's hook and a rule that lets it reach its model in every mode, raise `timeout_seconds` to at
least 60, offer to switch to ask mode, load the file (Touch ID) and start the daemon that runs the hook. In ask or
block-all it switches to accept-all while it works (Touch ID), and back if the setup stops. The agent's tools can only
read: no edits, no web.

| Agent | Signs in with | Model by default |
| --- | --- | --- |
| `fx` | Vercel (`fx login vercel`), billed to that team's AI Gateway | `anthropic/claude-haiku-5.5` |
| `claude-code` | Claude (`claude auth login`) | `haiku` |
| `codex` | a ChatGPT plan (`codex login`) | `gpt-6-luna` |
| `opencode` | the provider you pick: OpenAI, Z.AI Coding Plan, OpenCode Go, MiniMax Token Plan, OpenRouter or Anthropic | that provider's small one |

`--model NAME` picks another model (`PROVIDER/MODEL` for opencode). The agents approve plain developer and vendor
traffic for 8 to 24 hours, and anything less plain for 10 minutes to an hour. fx's test fails with HTTP 403
`customer_verification_required` when its Vercel team has no card on file, and with HTTP 502 `insufficient_funds` when
the team has no AI Gateway credits.

One agent answers at a time. Each one you connect keeps its hook, and `blackice mode ask --agent NAME` (`fx`,
`claude-code`, `codex`, `opencode`, or `you` to answer yourself) switches, with Touch ID, as the menu's Mode does. The
repository has each agent's hook and what it may do: [fx](../integrations/fx/README.md),
[Claude Code](../integrations/claude-code/README.md), [Codex](../integrations/codex/README.md),
[opencode](../integrations/opencode/README.md).

## Upgrade

Upgrade the way you installed: `brew upgrade --cask blackice` for the cask (it says "Cask 'blackice' is not installed"
after an install with the script), or the install script again with `--force`. Then right away:

```console
$ blackice start
```

`start` waits for the new extension and loads your configuration into it (Touch ID). If it exits with status 75, restart
the Mac and run it again. An open menu bar app reopens by itself.

## Uninstall

```console
$ blackice menu --login off
$ blackice agent uninstall
$ blackice stop
$ rm -rf /Applications/Blackice.app ~/.local/bin/blackice
```

Quit the menu first if it is open. `stop` asks for Touch ID and removes the filter and its extension; it needs no
network. With Homebrew, run `brew uninstall --cask blackice` in place of `rm`, after `blackice stop`: Homebrew cannot
remove the extension. Removing the app needs App Management for Terminal (System Settings → Privacy & Security → App
Management). `systemextensionsctl list` may show the extension waiting to uninstall until the next restart. Your
settings and logs stay; to remove them too: `rm -rf ~/.config/blackice ~/Library/Logs/blackice`.

## Rollback

If the network misbehaves in ask or block-all, switch back first, then look:

```console
$ blackice mode accept-all
```

A restart alone does not turn the filter off. If `blackice stop` fails, run it by its full path to see why
(`/Applications/Blackice.app/Contents/MacOS/blackice stop`), then:

1. System Settings → Network → Filters: remove blackice's content filter.
2. System Settings → General → Login Items: click ⓘ next to Blackice and turn off Network Extension (on macOS 15, Login
   Items & Extensions → Network Extensions).
3. `launchctl bootout gui/$(id -u)/com.valentorassa.blackice.daemon`, if the daemon is still loaded.
4. Move `/Applications/Blackice.app` to the Trash and restart.

These labels are from macOS 27.0.1.

To go back to an earlier version, uninstall, restart if `systemextensionsctl list` shows the extension waiting to
uninstall, then install the older one and allow the extension again. macOS replaces an extension only with the same or a
higher build.
