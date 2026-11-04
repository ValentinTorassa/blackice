# Claude Code integration (draft)

**The short way:** `blackice agent connect claude-code` does everything on this page in one command, and tries
Claude Code on a sample connection before it changes `blackice.toml`. The rest of this page is what it does, by
hand, and why.

[Claude Code](https://code.claude.com) decides blackice's ask-mode connections in print mode (`claude -p`). It
reads the event, weighs it, and ends its reply with one verdict line, which the daemon reads from the hook's
stdout: `approve 10m`, `approve 1h` or `deny`.

- [`blackice/instructions.md`](blackice/instructions.md): its whole system prompt. What it reads, what it weighs
  and how it answers, adapted from fx's skill.
- [`blackice/sample-event.json`](blackice/sample-event.json): an event as a hook gets it, with no token.

## The hook

```toml
[[hook]]
on = "connection"
run = 'CLAUDE_CONFIG_DIR="$HOME/.config/blackice/agent/.claude" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 /opt/homebrew/bin/claude -p --restricted --safe-mode --tools Read --strict-mcp-config --no-session-persistence --permission-prompts none --model sonnet --max-turns 3 --output-format text --system-prompt-file "$HOME/.config/blackice/agent/.claude/blackice/instructions.md" "Decide the pending blackice connection in event.json." </dev/null'
```

`agent connect` writes the same line with the paths spelled out, and the path of `claude` it found (the Homebrew
cask's `/opt/homebrew/bin/claude`, or `~/.local/bin/claude` from Anthropic's installer). Checked against Claude Code
2.1.317:

- **`--tools Read`**: reading files is its only tool. No shell, no edits, no web.
- **`--restricted`** keeps the file tools inside the working directory, which is the event's private directory
  with `event.json` alone in it: a read of `/etc/hosts` was refused. It also ignores the user, project and local
  settings files, so nothing in them can add a tool or a hook.
- **`--safe-mode`** turns off CLAUDE.md files, skills, plugins, hooks and the rest of the customizations, and
  **`--strict-mcp-config`** with no `--mcp-config` leaves no MCP server.
- **`--permission-prompts none`**: anything that would ask for permission is refused, since nobody is there.
- **`--no-session-persistence`**: nothing of the run is saved.
- **`--system-prompt-file`**: the instructions replace Claude Code's own system prompt.
- **`--model sonnet --max-turns 3`**: one turn to read the event and one to answer, with one to spare. Over the
  limit, `claude -p` exits with an error, and that is no answer.
- **`</dev/null`**: `claude -p` adds whatever comes on stdin to the prompt. The daemon sends the event there too,
  and closing it keeps the event out of the prompt: it arrives only through the Read tool, as data.
- **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`**: no telemetry, error reports or update checks, so the rule
  below can stay at two hosts.

## Signing in

The daemon starts each hook with `HOME` set to your own home (see the Daemon decision in
[`docs/plan.md`](../../docs/plan.md)), and the hook leaves it that way, unlike fx's. Claude Code keeps its sign-in in
the login keychain, and macOS finds that keychain through `HOME`: with `HOME` pointing anywhere else, `security
list-keychains` shows only the System keychain and `claude auth status` says it is not logged in.

What gives Claude Code a home of its own is `CLAUDE_CONFIG_DIR`. It reads its settings and state from that
directory, and names its keychain item after it (`Claude Code-credentials-` and the first 8 hex digits of the
directory's SHA-256). So the sign-in for blackice is apart from yours, and no secret is in `blackice.toml` or in a
file: the hook line holds only paths. A long-lived token from `claude setup-token` or an `ANTHROPIC_API_KEY` would
have to go in the hook's environment, which is the file.

```console
$ agent="$HOME/.config/blackice/agent"
$ mkdir -p -m 700 "$agent/.claude"
$ cp -R integrations/claude-code/blackice "$agent/.claude/"
$ CLAUDE_CONFIG_DIR="$agent/.claude" claude auth login
$ CLAUDE_CONFIG_DIR="$agent/.claude" claude auth status --text
```

`claude auth login` signs in with a Claude subscription, and its decisions count against that account's usage;
`--console` signs in for API billing instead. A sign-in through `ANTHROPIC_API_KEY` in your shell does not reach
the hook, which gets none of the shell's variables.

## Its own network

In ask mode, Claude Code's own connections must be covered by a rule bound to its signature, or it waits on its
own approval:

```toml
[[allow]]
app = "com.anthropic.claude-code"
team = "Q6L2SF6YDW"
hosts = ["api.anthropic.com", "platform.claude.com"]
```

`api.anthropic.com` is the model. `platform.claude.com` is where Claude Code 2.1.317 renews its sign-in (its OAuth
token endpoint); the renewal has not been seen under the hook yet. In the 20 eval runs and the probes before them,
on a Mac in ask mode with a rule for `*.anthropic.com`, the event log showed no other connection from Claude Code.
The Claude Code you use yourself reaches more (telemetry, updates, connectors), which the hook turns off.

## Checking it

[`../eval/run.sh`](../eval/run.sh) runs a decider over the events in [`../eval/events/`](../eval/events/) the way
the daemon runs a hook, and compares each verdict with [`../eval/cases.json`](../eval/cases.json):

```console
$ integrations/eval/run.sh --agent claude-code
```

It uses the sign-in in `~/.config/blackice/agent/.claude`; `CLAUDE_CONFIG_DIR=dir` picks another one, and
`MODEL=haiku` another model. On 4 November 2026, with Claude Code 2.1.317 and `sonnet` (claude-sonnet-5-5), signed
in through a personal configuration directory, one run came out 20 for 20:

- the six apps reaching their own services were approved, each for 1 hour, the cdhash-named Homebrew `gh`
  included;
- the lookalike hosts, the binaries in `~/Downloads`, `/tmp` and a hidden cache directory, the bare IP address,
  the odd ports (22, 6667, 8080, 8443), the event with no host and the three with instructions injected into the
  host or the path were denied;
- the injected `touch` never ran: there is no shell.

Each decision took 3 to 8 s, 4.1 s at the median. Ten replies put a sentence of reasoning before the reason
line they were asked for, two gave a paragraph in its place, and in every reply the verdict was the last line. One run with one
model shows the instructions can work, not that they always will.

## Open questions

- **Claude Code upgrades.** `--restricted`, `--safe-mode` and `--permission-prompts` are recent flags. An upgrade
  that renames or changes one changes what the hook allows. Run the eval again after upgrading.
- **Usage limits.** A subscription that hits its limit answers with an error, and every connection is denied at
  its deadline until the limit resets.
- **The model.** `sonnet` follows the latest Sonnet. Pinning a full model name makes runs comparable over time,
  and lags behind.
