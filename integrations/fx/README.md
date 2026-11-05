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
  weighs and how it answers.
- [`skills/blackice/sample-event.json`](skills/blackice/sample-event.json): an event as a hook gets it, without
  the token. A unit test in `macos/` decodes it, so the two stay in step.

## Installing the skill

fx looks for skills in `~/.fx/skills`, `~/.agents/skills` and `~/.claude/skills`, and in a
workspace's `.fx/skills`, `.agents/skills`, `.claude/skills` and `skills/`. For the hook it
goes in the agent's own home; the commands are under [Permissions](#permissions).

## The hook

fx v0.0.16 runs one request with `fx ask`; it has no `-p` flag. The hook in
`blackice.toml` is:

```toml
[[hook]]
on = "connection"
program = "/Users/me/.local/bin/fx"
app = "com.vercel.fx"
team = "JW6Y669B67"
args = ["ask", "--no-save", "--no-color", "Use the blackice skill to decide whether to approve the pending connection"]
env = ["HOME=/Users/me/.config/blackice/agent", "FX_DISABLE_KEYCHAIN=1"]
```

- **`program`** is the absolute path of fx. The daemon starts it directly, with `args`, and no shell.
- **`app`** and **`team`** are fx's signing identifier and Team ID, as in an `[[allow]]` rule. Read them with
  `codesign -dv ~/.local/bin/fx` (`Identifier=` and `TeamIdentifier=`). The daemon starts fx suspended, checks the
  signature of the process it started, and kills it before it runs if the signature does not name both. An
  upgrade of fx that keeps its identity needs no change; a program put in its place by something else never runs.
- **`env`** is added to the environment the daemon builds. `HOME` points fx at a home of its own, with its own
  login and the rules below, so they don't apply to the fx you use yourself. fx's documentation describes
  `FX_HOME` for this, but v0.0.16 does not read it. `FX_DISABLE_KEYCHAIN=1` keeps fx's login in that home rather
  than in your keychain.

The daemon starts each hook in a new private directory holding the event as `event.json`, and names that file in
`BLACKICE_EVENT_FILE`. That directory is fx's workspace, so fx can read the event without reaching outside it. The
event also goes to the hook on stdin, but `fx ask` treats stdin as its prompt, so the skill reads the file. The
event has no token: the hook never sees it.

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

The agent only has to read files: `event.json` and the skill. Set up its home once:

```console
$ agent="$HOME/.config/blackice/agent"
$ mkdir -p "$agent/.fx/skills"
$ cp -R integrations/fx/skills/blackice "$agent/.fx/skills/"
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
- Reading files is left alone: the agent has to read `event.json` and the skill.
- `fx permissions`, run with the same `HOME`, shows the mode and the rules fx loaded.

Don't add MCP servers to this home: their tools are not covered by these rules. And keep in mind that any program
running as you can change the skill, the rules and the login in this home, and through them what fx answers. The
signature check covers fx itself, not the files it reads.

## Checking the skill

[`eval/run.sh`](eval/run.sh) runs fx once per event in [`eval/events/`](eval/events/), the
way the hook would, with `BLACKICE_EVENT_FILE` set. It reads each answer from fx's stdout with the daemon's rules
(exit status 0, at most 64 KiB, the last non-empty line) and compares it with
[`eval/cases.json`](eval/cases.json). Nothing is allowed or blocked.

```console
$ AGENT_HOME="$HOME/.config/blackice/agent" integrations/fx/eval/run.sh /path/to/fx
```

Each event gets its own private directory with `event.json` and the repository's copy of the
skill in it, and fx runs there, as under the hook. `AGENT_HOME` is the `HOME` fx runs with; it defaults to yours.
`KEEP=1` keeps the work directory with fx's stdout, stderr and exit status for each event.

The fifteen events cover:

- apps reaching their own servers: VS Code, Chrome, Docker and GitHub Desktop;
- two programs signed ad hoc, named by their cdhash: a Homebrew `gh` reaching the GitHub API,
  and a binary in a hidden cache directory reaching a dynamic DNS name on port 8443;
- an unknown binary in `~/Downloads` reaching a paste site;
- a lookalike domain;
- SSH to a dynamic DNS name;
- three connections with no name, whose host is their address: `ssh` to a Tailscale address
  (approve), an unknown binary in `~/Downloads` to a public address on port 4444, and `curl` to
  a public address (both deny);
- an event with no host;
- instructions injected into the host and into the app path.

The eval has not run with the 0.4.0 skill yet, nor with the three events that name an address. With the 0.3 skill,
which had fx run `blackice approve` and `deny` with the token, against a stub:

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
