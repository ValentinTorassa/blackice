# fx integration: a blackice scope for every command fx runs

This directory holds a small patch to [fx](https://github.com/vercel-labs/fx) v0.0.16
(commit `481104fdbc247aab4e987e875402dc735e82642e`). It adds one built-in `PreToolUse` hook.
Set `FX_BLACKICE_POLICY` and every shell command fx starts runs inside its own blackice
task scope.

This is a declared patch, not an upstream fx feature. In v0.0.16, fx hooks can only be
compiled-in handlers; fx has no configuration or plugin interface for them. So the
integration is a patched build of fx, and this patch is the whole difference.

## What the hook does

The hook runs before fx validates, reviews or runs a tool call.

| Tool call | What happens |
|---|---|
| `shell` that starts a command (`action: "run"`, or a `command` with no action) | The command becomes `'<blackice>' run --policy '<policy>' -- '<shell>' -c '<command>'`. It runs in a new task scope with its own proxy, receipts and a clean environment. |
| `shell` `interact` / `stop` | Unchanged. These talk to a session that was already started inside a scope. |
| `web_fetch`, `web_search` | Blocked. These tools run inside fx itself, outside every scope. Use a shell command such as `curl`; it runs under the policy. |
| A call the hook cannot read safely | Blocked, never run unscoped. That covers a `request` wrapper, a command that is not a string or contains a NUL byte, a shell that is not sh, bash or zsh, and a misconfigured `FX_BLACKICE_POLICY` or `FX_BLACKICE_BIN`. |

The command is single-quoted, so nothing inside it is interpreted by the outer shell. The
inner shell is the call's own `shell.path`, or `$SHELL` when that is sh, bash or zsh, or else
`/bin/sh`. It starts without startup files (`zsh -f`, `bash --noprofile --norc`), so those
files cannot export secrets back into the scope.

## Build

You need git and Zig 0.17.0.

```sh
integrations/fx/build.sh                                # builds ./fx-blackice/zig-out/bin/fx
ZIG_TARGET=aarch64-macos integrations/fx/build.sh       # cross-compile for an Apple silicon Mac
```

The script clones the v0.0.16 tag, checks that the tag resolves to the commit above,
applies `fx-v0.0.16-blackice-hook.patch` and builds with `-Doptimize=ReleaseSafe`.

## Use

```sh
export FX_BLACKICE_POLICY=/absolute/path/policy.json    # turns the hook on
export FX_BLACKICE_BIN=/absolute/path/blackice          # optional; default: blackice from PATH
./fx-blackice/zig-out/bin/fx
```

Each command fx runs prints the scope it got, for example:

```
blackice: scope s-1369ea22 (policy b28c9f29dbea, macos-seatbelt); receipts: …/scopes/s-1369ea22/receipts.jsonl
```

The scope's receipts record each network decision. To allow one more host in a running
scope for a while, run `blackice grant <scope> <host> --for 10m` from outside it.

## Limits in v0

- fx itself, and its traffic to the model, run outside the scopes. Only the commands it
  starts are confined.
- fx's own network tools (`web_fetch`, `web_search`) are blocked, not scoped. MCP servers
  and the ACP editor integration are not covered.
- fx's permission modes still apply, to the rewritten command. In `auto` mode, fx's
  classifier does not recognize `blackice run …`, so those commands go to fx's reviewer. In
  full-access mode they run directly.
- Each command runs in a new shell in a new scope. A `cd` or `export` in one command does not
  carry over to the next.
- Only sh, bash and zsh are supported. Aliases and functions from shell startup files are not
  loaded.
- Task scopes are clients only. A command cannot start a server that listens, not even on
  loopback.

## Checked

On macOS 27.0.1 (26A434), arm64, with SIP on, using fx v0.0.16 with this patch, blackice
`claude/run`, and a **scripted test model** (not a real model) on loopback:

- fx ran four commands, and blackice created four scopes, one per command.
- `curl https://example.com` → 200, allowed by rule, with a receipt.
- `curl https://github.com` → proxy 403, `no_matching_rule`, with a receipt.
- `curl --noproxy '*' https://example.com` → refused by the OS (curl exit 6).
- A variable set in fx's environment did not reach the command.

## License

fx is licensed under Apache-2.0 by its authors. This patch modifies fx: it adds
`src/builtins/hooks/blackice.zig` and registers that hook in `src/main.zig`,
`src/core/cli/cli_ask.zig` and `src/builtins/hooks.zig`. The patch is distributed under
Apache-2.0, like the rest of blackice.
