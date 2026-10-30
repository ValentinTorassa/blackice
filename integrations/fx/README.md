# fx integration: a blackice scope for every command fx runs

This directory holds a small patch to [fx](https://github.com/vercel-labs/fx) v0.0.16
(commit `481104fdbc247aab4e987e875402dc735e82642e`). It adds one built-in `PreToolUse` hook.
Set `FX_BLACKICE_POLICY` and `FX_BLACKICE_BIN`, and every shell command fx starts runs inside
its own blackice task scope. One command cannot make the next one run unscoped.

This is a declared patch, not an upstream fx feature. In v0.0.16, fx hooks can only be
compiled-in handlers; fx has no configuration or plugin interface for them. So the
integration is a patched build of fx, and this patch is the whole difference.

## What the hook does

At start, the hook pins the policy (its sha256) and finds fx's own executable. It then runs
before fx validates, reviews or runs each tool call.

| Tool call | What happens |
|---|---|
| `shell` that starts a command (`action: "run"`, or a `command` with no action) | The command becomes `'<blackice>' run --policy-sha256 '<hash>' --protect '<fx>' --policy '<policy>' -- '<shell>' '-f' '-c' '<command>'`, and the call gets `profile: "clean"`. It runs in a new task scope with its own proxy, receipts and a clean environment. |
| `shell` with `tty: true`, `reload: true` or a `shell` field | Blocked. A tty session runs fx's terminal bootstrap outside the scope, and reload re-reads startup files. |
| `shell` `interact` / `stop` | Unchanged. These talk to a command that was already started inside a scope. |
| `read_file`, `write_file`, `edit_file`, `glob_files`, `grep_files`, `ask_user_question`, `read_tool_result`, `skill`, `subagent` | Unchanged. They act on local files or on the conversation. A subagent's calls go through this same hook. |
| Any other tool: `web_fetch`, `web_search`, `install_skill`, `mcp_select_tool`, MCP tools, `vision`, `capability_search`, and tools added later | Blocked. They would act from fx itself, outside every scope. Use a shell command such as `curl`; it runs under the policy. |
| A call the hook cannot read safely | Blocked, never run unscoped. That covers a `request` wrapper and a command that is not a string or contains a NUL byte. A misconfiguration blocks every call. |

Why one command cannot unscope the next:

- fx's own outer shell starts clean (`profile: "clean"`, so `zsh -f` or `bash --noprofile
  --norc`). A command in a scope can edit `~/.zshrc`, but the next command's outer shell,
  which runs outside the scope, never reads it.
- blackice refuses to start a scope if the policy no longer matches the hash pinned at fx
  start.
- Inside every scope, blackice refuses writes to its own executable, to the policy file and to
  fx's executable (fx re-runs its own binary for each command on macOS), and refuses renaming
  their parent directories.
- `FX_BLACKICE_BIN` must be an absolute path with no symlinks, so the path fx runs is the one
  blackice protects.

The command is single-quoted, so nothing inside it is interpreted by the outer shell. The
inner shell is `$SHELL` when that is sh, bash or zsh, or else `/bin/sh`. It also starts
without startup files, so those files cannot export secrets back into the scope.

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
export FX_BLACKICE_POLICY=/absolute/path/policy.json    # turns the hook on; pinned at start
export FX_BLACKICE_BIN=/absolute/path/blackice          # required; its real path, no symlinks
./fx-blackice/zig-out/bin/fx
```

A change to the policy file takes effect when fx restarts. Until then, a scope refuses to
start with the changed file. `fx acp` refuses to start while `FX_BLACKICE_POLICY` is set,
because the ACP server has no hook.

Each command fx runs prints the scope it got, for example:

```
blackice: scope s-1369ea22 (policy b28c9f29dbea, macos-seatbelt); receipts: …/scopes/s-1369ea22/receipts.jsonl
```

The scope's receipts record each network decision. To allow one more host in a running
scope for a while, run `blackice grant <scope> <host> --for 10m` from outside it.

## Limits in v0

- fx itself, and its traffic to the model, run outside the scopes. Only the commands it
  starts are confined.
- fx's own network tools and MCP tools are blocked, not scoped. `fx acp` refuses to start
  in this mode.
- A command in a scope can still change ordinary files of the user, such as `~/.zshrc`. fx
  never reads them in this mode, but the user's own terminal will. blackice limits the
  network; it is not a file sandbox.
- fx's permission modes still apply, to the rewritten command. In `auto` mode, fx's
  classifier does not recognize `blackice run …`, so those commands go to fx's reviewer. In
  full-access mode they run directly.
- Each command runs in a new shell in a new scope. A `cd` or `export` in one command does not
  carry over to the next.
- Only sh, bash and zsh are supported. Aliases and functions from shell startup files are not
  loaded, and interactive (tty) commands are off.
- On Linux the backend must keep blackice, the policy and fx read-only inside the scope.
  Until it does, `blackice run` refuses to start any scope there.
- Task scopes are clients only. A command cannot start a server that listens, not even on
  loopback.

## Checked

On macOS 27.0.1 (26A434), arm64, with SIP on, using fx v0.0.16 with this patch, blackice
`claude/run` at ca62d58, and a **scripted test model** (not a real model) on loopback:

- fx ran eight shell commands, and blackice created eight scopes, one per command. Each
  scope_start says "3 protected files; policy pinned".
- `curl https://example.com` → 200, allowed by rule, with a receipt.
- `curl https://github.com` → proxy 403, `no_matching_rule`, with a receipt.
- `curl --noproxy '*' https://example.com` → refused by the OS (curl exit 6), with a
  `kernel_drop` receipt.
- One command appended `touch` lines to `~/.zshrc`, `~/.zshenv` and `~/.zprofile` (in a test
  `HOME`). The next command ran, and no marker file appeared.
- One command tried to overwrite the policy, blackice and fx. All three writes were refused
  ("operation not permitted", three `protected_path` receipts), and the three files' hashes
  did not change. The next `curl https://github.com` was still refused.
- `tty: true`, `reload: true`, `web_fetch` and `install_skill` calls were blocked with a
  message to the model.
- `FAKE_SECRET`, set in fx's environment, did not reach the command; `AI_AGENT=fx` did.

## License

fx is licensed under Apache-2.0 by its authors. This patch modifies fx: it adds
`src/builtins/hooks/blackice.zig` and registers that hook in `src/main.zig`,
`src/core/cli/cli_ask.zig` and `src/builtins/hooks.zig`. The patch also makes
`src/acp/server.zig` refuse to start in blackice mode. The patch is distributed under
Apache-2.0, like the rest of blackice.
