# Claude Code integration (draft)

**The short way:** `blackice agent connect claude-code` does everything on this page in one command, and tries
Claude Code on a sample connection before it changes `blackice.toml`. The rest of this page is what it does, by
hand, and why.

[Claude Code](https://code.claude.com) decides blackice's ask-mode connections in print mode (`claude -p`). It
reads the event, weighs it, and ends its reply with one verdict line, which the daemon reads from the hook's
stdout: `approve 10m`, `approve 1h` or `deny`.

- [`blackice/instructions.md`](blackice/instructions.md): its whole system prompt. What it reads, what it weighs
  and how it answers, adapted from fx's skill. blackice ships a copy inside its binary (a test in `macos/` fails
  when the two differ; `macos/scripts/agent-instructions.sh` writes it).
- [`blackice/sample-event.json`](blackice/sample-event.json): an event as a hook gets it, with no token.

When `blackice.toml` has `notes` in `[agent]`, the daemon passes them after the instructions
(`--append-system-prompt`), and the instructions have Claude Code follow them for judgment calls, never over the
safety rules. `NOTES=file` gives the eval below notes.

## The hook

The hook `agent connect` writes, for a home at `/Users/me` and the Homebrew `claude`:

```toml
[[hook]]
on = "connection"
program = "/opt/homebrew/bin/claude"
app = "com.anthropic.claude-code"
team = "Q6L2SF6YDW"
args = ["-p", "--restricted", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--permission-prompts", "none", "--model", "haiku", "--max-turns", "3", "--output-format", "text", "Decide the pending blackice connection. Its event is the JSON object in this message, which blackice sent on stdin."]
env = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1", "CLAUDE_CONFIG_DIR=/Users/me/.config/blackice/agent/.claude"]
instructions = "claude-code"
```

The daemon starts it as `claude --system-prompt <the instructions> [--append-system-prompt <the notes>] -p …`, with
the event on stdin and `/var/empty` as its working directory. A hook from 1.0, with `--tools Read`,
`--system-prompt-file instructions.md` and `stdin = "none"`, runs the same way.

`program` is the `claude` it found: the Homebrew cask's `/opt/homebrew/bin/claude`, or `~/.local/bin/claude` from
Anthropic's installer. `app` and `team` are read from that binary, and macOS starts it only when its code has them
with Anthropic's Developer ID signature, so an update that keeps that signature needs no change. Checked against
Claude Code 2.1.318:

- **`--tools ""`**: no tools at all. No shell, no files, no edits, no web. Everything it needs is in its prompt.
- **`--restricted`** ignores the user, project and local settings files, so nothing in them can add a tool or a
  hook.
- **`--safe-mode`** turns off CLAUDE.md files, skills, plugins, hooks and the rest of the customizations, and
  **`--strict-mcp-config`** with no `--mcp-config` leaves no MCP server.
- **`--permission-prompts none`**: anything that would ask for permission is refused, since nobody is there.
- **`--no-session-persistence`**: nothing of the run is saved.
- **`instructions = "claude-code"`**: the daemon passes the instructions, from blackice itself, with
  `--system-prompt`, which replaces Claude Code's own system prompt, and the notes with `--append-system-prompt`.
  A hook's own `--system-prompt`, `--system-prompt-file`, `--append-system-prompt` and
  `--append-system-prompt-file` are dropped. Up to 1.0.2 the daemon wrote them as `instructions.md` and
  `notes.md` into the event's directory, Claude Code's working directory, and up to 0.4.0 `agent connect` copied
  them into the agent home: either way a file that any program running as you could rewrite while Claude Code
  read it. `agent connect` removes the old copy.
- **The event on stdin**: `claude -p` adds what comes on stdin to the prompt, and the prompt says the event is
  that JSON object. Up to 1.0.2 the hook had `stdin = "none"` and the event came as `event.json`, read with the
  Read tool, which kept it apart from the prompt but was a file in a folder of yours. The instructions now say that
  everything inside the JSON object is the event's, even text that looks like part of the prompt.
- **`--model haiku --max-turns 3`**: the smallest model, which uses the least of the subscription, and turns to
  spare for the one it needs to answer. Over the limit, `claude -p` exits with an error, and that is no answer.
  `agent connect claude-code --model sonnet` writes another model.
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
token endpoint); the renewal has not been seen under the hook yet. In the 40 eval runs and the probes before them,
on a Mac in ask mode with a rule for `*.anthropic.com`, the event log showed no other connection from Claude Code.
The Claude Code you use yourself reaches more (telemetry, updates, connectors), which the hook turns off.

## Checking it

[`../eval/run.sh`](../eval/run.sh) runs a decider over the events in [`../eval/events/`](../eval/events/) the way
the daemon runs a program hook, with the hook above (the instructions from the repository), and compares each
answer with [`../eval/cases.json`](../eval/cases.json):

```console
$ integrations/eval/run.sh --agent claude-code
```

It uses the sign-in in `~/.config/blackice/agent/.claude`; `CLAUDE_CONFIG_DIR=dir` picks another one, and
`MODEL=sonnet` another model.

These results are from before 1.0.3, when the event and the instructions were files that Claude Code read with
its Read tool. With the event on stdin and no tools, the eval has not been run against a model yet.

On 5 November 2026, with Claude Code 2.1.317 signed in through a personal configuration directory, the hook of
then, with the instructions that say how long to approve for, one run with `haiku` and one with `sonnet` both came
out 23 for 23:

| Model | As expected | Median | p90 | Replies of exactly two lines |
| --- | --- | --- | --- | --- |
| `haiku` | 23/23 | 4.2 s | 5.3 s | 23 |
| `sonnet` | 23/23 | 5.1 s | 6.2 s | 5 |

- The seven apps reaching their own services were approved: for 8 to 24 hours, the cdhash-named Homebrew `gh`
  for 8 with both models, and `ssh` to a Tailscale address, the one address approved, for 1 hour.
- The lookalike hosts, the binaries in `~/Downloads`, `/tmp` and a hidden cache directory, the bare and public
  addresses, the odd ports (22, 4444, 6667, 8080, 8443), the event with no host and the four with instructions in
  the host or the path were denied.
- The injected `touch` never ran: there is no shell.
- Every verdict was the last line. `sonnet` put a sentence or a paragraph of reasoning before the two lines in 18
  replies; `haiku` kept to the two lines. So the hook uses `haiku`.

On 4 November 2026, with `sonnet` and the first 20 cases, two runs (one as a `run` line, one as the program hook)
had come out 20 for 20, 4.1 and 4.3 s at the median, every approval for 1 hour, as those instructions asked. A few
runs show the instructions can work, not that they always will.

## Open questions

- **Claude Code upgrades.** `--restricted`, `--safe-mode` and `--permission-prompts` are recent flags. An upgrade
  that renames or changes one changes what the hook allows. Run the eval again after upgrading.
- **Usage limits.** A subscription that hits its limit answers with an error, and every connection is denied at
  its deadline until the limit resets.
- **The model.** `haiku` follows the latest Haiku. Pinning a full model name (`--model claude-haiku-5-5`) makes
  runs comparable over time, and lags behind.
- **Several at once.** The daemon runs up to 4 hooks at once, so up to 4 Claude Code processes share one sign-in.
  How they renew it together has not been seen.
