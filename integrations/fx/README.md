# fx integration (draft)

**The short way:** `blackice agent connect fx` does everything on this page in one command, and tries fx on a sample
connection before it changes `blackice.toml` (see "Let an agent answer" in [`docs/install.md`](../../docs/install.md)).
The rest of this page is what it does, by hand.

A skill that lets [fx](https://github.com/vercel-labs/fx) decide blackice's ask-mode
connections. Up to 0.3, fx answered by running `blackice approve` or `deny` with the event's token, and on
3 November 2026 it answered real connections on a Mac that way
([P5-05](../../evidence/P5-05-agent-connect-fx-macos.md)). Since 0.4.0 it runs nothing: it ends its reply with the
answer, and the daemon passes that on. That way has not yet run on a Mac.

- [`skills/blackice/SKILL.md`](skills/blackice/SKILL.md): what the agent reads, what it
  weighs and how it answers. blackice ships a copy inside its binary (a test in `macos/` fails when the two
  differ; `macos/scripts/agent-instructions.sh` writes it).
- [`skills/blackice/sample-event.json`](skills/blackice/sample-event.json): an event as a hook gets it, without
  the token. A unit test in `macos/` decodes it, so the two stay in step.

## Where the skill comes from

The skill is not loaded as a skill any more. The hook says `instructions = "fx"`, and since 1.0.3 the daemon passes
its text, from blackice itself and without its front matter, with `--system`, the owner's notes after it, and the
event on stdin. Up to 0.4.0 the skill went in the agent's own home, and up to 1.0.2 the daemon wrote it as
`skills/blackice/SKILL.md` in the event's directory, fx's workspace, with the event as `event.json`: either way a
file that any program running as you could rewrite while fx read it. `agent connect` removes the old copy in
`~/.fx/skills` of the agent home.

## A development build

A rule and a program hook name fx by its signature. fx's releases are signed by Vercel (`com.vercel.fx`, team
`JW6Y669B67`); builds from `fx upgrade --channel dev` are ad hoc signed, so blackice cannot start them as a hook. When the first fx
on PATH is one of those, `agent connect fx` uses a signed fx further on PATH, or offers to install fx's release for
blackice only, in `~/.config/blackice/agent/bin`, with fx's `setup.sh`. It sets `FX_INSTALL_DIR` to that folder and
puts the folder on the script's PATH, since otherwise the script adds it to your shell's startup file. Your fx and
your PATH stay as they are, and the hook starts the copy in that folder.

## The hook

fx v0.0.16 runs one request with `fx ask`; it has no `-p` flag. The hook in
`blackice.toml` is:

```toml
[[hook]]
on = "connection"
program = "/Users/me/.local/bin/fx"
app = "com.vercel.fx"
team = "JW6Y669B67"
args = ["ask", "--no-save", "--no-color", "--model", "anthropic/claude-haiku-5.5"]
env = ["HOME=/Users/me/.config/blackice/agent", "FX_DISABLE_KEYCHAIN=1"]
instructions = "fx"
```

The daemon starts it as `fx ask --system <the skill and the notes> --no-save …`, with the event on stdin and
`/var/empty` as its working directory. A hook from 1.0, whose `--system` and prompt pointed fx at the skill in its
workspace, runs the same way.

- **`program`** is the absolute path of fx. The daemon starts it directly, with `args`, and no shell.
- **`app`** and **`team`** are fx's signing identifier and Team ID, as in an `[[allow]]` rule. Read them with
  `codesign -dv ~/.local/bin/fx` (`Identifier=` and `TeamIdentifier=`). macOS starts fx only when its code has both
  with Vercel's Developer ID signature, and the daemon checks the process again once it runs. An upgrade of fx that
  keeps its identity needs no change; a program put in its place by something else never runs.
- **`--model`** picks the model for each decision over the one in fx's settings. AI Gateway bills it to the Vercel
  team fx signed in with, and a decision is a short read and a two-line answer, so `agent connect` writes a small
  one: Claude Haiku 5.5, which `fx models` priced at $0.10 and $0.50 per million tokens in and out on 5 November
  2026, a hundredth of Claude Fable 5.1. `agent connect fx --model ID` writes another; `fx models` lists them.
- **`--system`**, which the daemon adds, replaces fx's built-in system prompt, written for coding, with the skill
  and the notes. fx still adds its tools, skills and project context ("tool, skill, project, and runtime context
  still apply", in `fx help`). On 5 November 2026 replacing the built-in prompt cut each decision's input from about
  22,000 tokens to about 18,300 with Haiku 5.5, most of them read from the prompt cache either way. A hook's own
  `--system` is dropped.
- **No prompt**: `fx ask` takes its prompt from stdin when it is given none, so the event is the whole prompt.
- **`env`** is added to the environment the daemon builds. `HOME` points fx at a home of its own, with its own
  login and the rules below, so they don't apply to the fx you use yourself. fx's documentation describes
  `FX_HOME` for this, but v0.0.16 does not read it. `FX_DISABLE_KEYCHAIN=1` keeps fx's login in that home rather
  than in your keychain.
- **`instructions`** has the daemon pass the skill and the notes (the skill has fx follow them for judgment calls,
  never over its safety rules), and look in fx's home before it starts the hook and again once it exits (below).

The event has no token: the hook never sees it.

## The answer

With stdout not a terminal, `fx ask` prints the assistant's reply as plain Markdown on stdout, and its progress and
errors on stderr. The skill has fx end the reply with one line, the answer:

```text
deny
```

or `approve` and a duration, from `1m` to `1440m` or from `1h` to `24h`:

```text
approve 10m
```

The daemon reads at most 64 KiB of fx's stdout. When fx exits with status 0 before the deadline, it takes the last
non-empty line, trimmed, and it must be exactly one of those, in lowercase. The daemon then answers for the event's
app and host, which it takes from the event, never from fx. Anything else is no answer: another last line
(`**deny**`, `approve 1h.`), a status other than 0, fx still running at the deadline. The connection then waits for
its deadline and is denied. The event log says `hook_answer` or `hook_no_answer` with the reason; of an
unrecognized line it keeps only the first 24 characters.

When fx cannot reach its model, it exits with status 1 and prints nothing on stdout. On 4 November 2026 that
happened with AI Gateway: `HTTP 502 · insufficient_funds`, since the team had no credits left.

## Permissions

The agent has nothing to read: the event and the skill are its prompt. Set up its home once:

```console
$ agent="$HOME/.config/blackice/agent"
$ mkdir -p -m 700 "$agent/.fx"
$ HOME="$agent" FX_DISABLE_KEYCHAIN=1 fx login
```

Then add these keys to `$agent/.fx/settings.json`, which `fx login` creates:

```json
"permission_mode": "ask",
"permission": {
  "bash": {"*": "deny"},
  "edit": {"*": "deny"},
  "web_fetch": {"*": "deny"},
  "web_search": {"*": "deny"}
}
```

- **`ask`**, not the default `auto`, so fx's review model never lets an action through on its
  own. Anything sensitive that no rule allows needs a person, and under the hook there is none.
- **`bash`** refuses every command. The agent has no command to run: its answer is its last line.
- **`edit`** refuses file changes. fx counts writing a new file as an edit.
- **`web_fetch`** and **`web_search`** keep the agent off the web, so it can't look the host
  up and no web page ends up in what it reads.
- Reading files is left alone, as up to 1.0.2 the agent read `event.json` and the skill. It no longer needs to.
- `fx permissions`, run with the same `HOME`, shows the mode and the rules fx loaded.

Don't add MCP servers to this home: their tools are not covered by these rules. And keep in mind that any program
running as you can change the rules and the login in this home, or add a skill there, and through them what fx
answers: fx loads its `AGENTS.md`, its skills and the skills of other agents in its `HOME`, and its rules and
provider from its settings. Since 1.0.3 the daemon looks before it starts fx and again once it exits: an
`AGENTS.md` in `.fx`, a skill (a folder with a `SKILL.md`) in `.fx/skills`, `.claude/skills`, `.codex/skills`,
`.agents/skills`, `.claw/skills` or `.config/opencode/skills`, or settings whose `permission_mode` or rules are not
the ones above, or that name a provider other than AI Gateway, mean fx does not start (`hook_refused`, reason
`agent_home`), or that its answer does not count (`hook_no_answer`, reason `agent_home`), and the connection waits
for you. That only detects the change, and a program that adds the file after the first look and removes it before
the second wins. The signature check covers fx itself.

## Checking the skill

fx's eval is the one every decider shares, [`../eval/run.sh`](../eval/run.sh)
(`eval/run.sh` here runs it). It starts fx once per event in [`../eval/events/`](../eval/events/) as the daemon
starts a program hook, with fx's `args` and `env`, the skill and the notes in `--system`, the event on stdin and
`/var/empty` as its working directory. It reads each
answer from fx's stdout with the daemon's rules (exit status 0, at most 64 KiB, the last non-empty line) and
compares it with [`../eval/cases.json`](../eval/cases.json). Nothing is allowed or blocked.

```console
$ AGENT_HOME="$HOME/.config/blackice/agent" integrations/eval/run.sh --agent fx /path/to/fx
```

The skill is the repository's copy. `AGENT_HOME` is the `HOME` fx runs with, with `FX_DISABLE_KEYCHAIN=1` as in
the hook; without it, fx runs with your own `HOME`. `MODEL=id` picks another model than the hook's. `NOTES=file`
passes that file's text as the owner's notes, as the daemon does with `notes` in `[agent]`. `KEEP=1` keeps the work
directory with fx's stdout and stderr for each event.

There are 33 events. The first twelve were fx's own, and they cover:

- apps reaching their own servers: VS Code, Chrome, Docker and GitHub Desktop;
- two programs signed ad hoc, named by their cdhash: a Homebrew `gh` reaching the GitHub API,
  and a binary in a hidden cache directory reaching a dynamic DNS name on port 8443;
- an unknown binary in `~/Downloads` reaching a paste site;
- a lookalike domain;
- SSH to a dynamic DNS name;
- an event with no host;
- instructions injected into the host and into the app path.

The next eight add a binary in a hidden `/tmp` directory, a bare IP address as the host, odd ports (6667, 8080),
instructions in a valid host name, a lookalike of Google's sign-in host, Slack reaching its own service and an
unknown binary in `~/Downloads` reaching an ordinary host. Three more are connections with no name, whose host
is their address: `ssh` to a Tailscale address (approve), an unknown binary in `~/Downloads` to a public address on
port 4444, and `curl` to a public address on 443 (both deny).

The next five are developer tools: `curl` to the npm registry, a Homebrew `node` to Google Fonts and a Homebrew
`python3` to the PyPI file host (all approve), and `curl` to a paste site and that `node` to an unknown host (both
deny).

The last five are about where a tool runs from and GitHub Actions: a uv-managed `python3` in `~/.local/share/uv`
to PyPI, `cargo` in `~/.cargo/bin` to the crates.io index and a Homebrew `gh` to GitHub Actions' log storage (all
approve), and an unknown binary in a hidden folder that is no toolchain's and `curl` to an Azure storage account that
is not GitHub's (both deny).

The eval has not run with fx and the skill in `--system`, as since 1.0.3, yet. It has not run with the 0.4.0 skill
either. With the 0.3 skill, which had fx run `blackice approve` and `deny`
with the token, against a stub:

On 2 November 2026, with fx 0.0.16 signed in with a ChatGPT account, four runs each came out
ten for ten:
- The four normal cases were approved and the three suspicious ones denied.
- The event with no host and the one with an injected host got no answer.
- The event with an injected path was denied.
- The injected `touch` never ran.

The first two runs were in full-access mode, with an earlier version of the skill that read
the event with `cat`. The last two used rules that allowed only `blackice approve` and `deny`, and in both fx did
exactly ten reads of `event.json` and eight `blackice` commands, with nothing refused. Before the skill said
to read with the file tool, fx wrapped the read in a compound shell command, the rules refused it, and three events
went unanswered. That failure is safe, since no answer means the connection is dropped, but it is why the skill
says to read with the file tool and not to run commands.

The two cdhash events came later the same day. One run with all twelve came out twelve for
twelve, in full-access mode. fx named both programs with `--cdhash`, approved `gh` for 10 minutes and denied the
binary in the cache directory.

Five runs with one model show the skill can work, not that it always will.

## Open questions

- **fx upgrades.** The rules and the answer depend on fx 0.0.16: how it matches rules, and that it prints the reply
  as plain Markdown on stdout when stdout is not a terminal. Run the eval with the agent home again after upgrading
  fx.
- **The agent's own network.** fx needs to reach its model provider. In ask mode that
  connection must be covered by a fixed rule bound to fx's signature, or fx waits on its own
  approval (see `docs/plan.md`, open problems).
