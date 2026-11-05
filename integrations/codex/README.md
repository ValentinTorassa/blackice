# Codex integration (draft)

**The short way:** `blackice agent connect codex` does everything on this page in one command, and tries Codex on a
sample connection before it changes `blackice.toml`. The rest of this page is what it does, by hand, and why.

[Codex](https://developers.openai.com/codex/cli) decides blackice's ask-mode connections with `codex exec`, signed
in with a ChatGPT plan. It reads the event, weighs it, and ends its final message with one verdict line, which the
daemon reads from the hook's stdout: `approve 12h`, `approve 30m` or `deny`. `codex exec` prints only its final
message on stdout; its progress goes to stderr.

- [`instructions.md`](instructions.md): its whole base prompt. What it reads, what it weighs and how it answers,
  in step with fx's skill and Claude Code's instructions. blackice ships a copy inside its binary (a test in
  `macos/` fails when the two differ; `macos/scripts/agent-instructions.sh` writes it).

## The hook

The hook `agent connect` writes, for a home at `/Users/me` and the Homebrew cask's `codex`:

```toml
[[hook]]
on = "connection"
program = "/opt/homebrew/bin/codex"
app = "codex"
team = "2DC432GLL2"
args = ["exec", "--strict-config", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--color", "never", "-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"low\"", "-c", "model_instructions_file=\"instructions.md\"", "-c", "project_doc_max_bytes=0", "-c", "default_permissions=\"blackice\"", "-c", "permissions.blackice.filesystem={\":minimal\"=\"read\",\":workspace_roots\"=\"read\"}", "-c", "approval_policy=\"never\"", "-c", "allow_login_shell=false", "-c", "web_search=\"disabled\"", "-c", "analytics.enabled=false", "-c", "feedback.enabled=false", "-c", "history.persistence=\"none\"", "--disable", "hooks", "--disable", "plugins", "--disable", "apps", "--disable", "multi_agent", "--disable", "image_generation", "--disable", "browser_use", "--disable", "computer_use", "Decide the pending blackice connection described in event.json."]
env = ["CODEX_HOME=/Users/me/.config/blackice/agent/.codex"]
stdin = "none"
instructions = "codex"
```

`program` is the `codex` it found on `PATH` or in the usual folders. `app` and `team` are read from that binary
(`codesign -dv`: `Identifier=codex`, `TeamIdentifier=2DC432GLL2`), and the daemon starts it only when the running
code has them. Checked against Codex 0.166.0:

- **`model_instructions_file="instructions.md"`** and **`instructions = "codex"`**: before Codex starts, the daemon
  writes the instructions, from blackice itself, as `instructions.md` in the event's directory, its working
  directory, and they replace Codex's own base prompt. The path is relative to that directory.
- **`default_permissions="blackice"`** with **`:minimal` and `:workspace_roots` read**: Codex reads the event with a
  shell command (`cat event.json notes.md`), and its commands run in a sandbox that can read the event's directory
  and the system's own files, write nothing, and reach no network. A command that reads `~/.zshrc` gets "Operation
  not permitted", and so does `touch`. The hook does not say `--sandbox read-only`: that sandbox reads the whole disk, your home
  included, and when both are given it takes the place of the profile (seen on 5 November 2026: with both, the
  same command printed the file).
- **`approval_policy="never"`**: nothing asks for approval, and nothing runs outside the sandbox.
- **`--ignore-user-config`**, **`--ignore-rules`**, **`project_doc_max_bytes=0`**: no `config.toml`, so no MCP
  servers or profiles; no exec-policy rules; no `AGENTS.md` from the working directory. **`--disable`** turns off
  hooks, plugins, apps, subagents, image generation and browser and computer use, and **`web_search="disabled"`**
  the web search tool. **`--strict-config`** refuses a key this version of Codex does not know, so a renamed key
  stops the hook instead of being ignored.
- **`--ephemeral`**, **`history.persistence="none"`**, **`analytics.enabled=false`**, **`feedback.enabled=false`**:
  nothing of the run is saved, and nothing is sent but the request.
- **`allow_login_shell=false`**: its commands run in a plain `zsh`, which reads no login files.
- **`-m gpt-6-luna`** and **`model_reasoning_effort="low"`**: the small model of Codex 0.166.0's list ("fast and
  affordable model for easier tasks"), with little reasoning, since a decision is a short read and a two-line
  answer. `agent connect codex --model NAME` writes another.
- **`stdin = "none"`**: `codex exec` adds what comes on stdin to its prompt. With an empty stdin the event reaches
  Codex only as the file it reads, as data.
- **`--skip-git-repo-check`**: the event's directory is not a Git repository.

## Signing in

`CODEX_HOME` gives Codex a home of its own, `~/.config/blackice/agent/.codex`, apart from yours in `~/.codex`.
`HOME` stays your own, as the daemon sets it.

```console
$ agent="$HOME/.config/blackice/agent"
$ mkdir -p -m 700 "$agent/.codex"
$ CODEX_HOME="$agent/.codex" codex login
$ CODEX_HOME="$agent/.codex" codex login status
Logged in using ChatGPT
```

`codex login` opens a sign-in page and waits for it on a port of this Mac (loopback passes in every mode).
`codex login --device-auth` signs in with a code instead, for a browser on another device. Its decisions count
against that ChatGPT plan. Codex keeps the sign-in in `auth.json` in that home, readable only by you. An
`OPENAI_API_KEY` in your shell does not reach the hook, which gets none of the shell's variables; with no sign-in,
Codex 0.166.0 tries `api.openai.com` and stops at HTTP 401.

## Its own network

In ask mode, Codex's own connections must be covered by a rule bound to its signature, or it waits on its own
approval:

```toml
[[allow]]
app = "codex"
team = "2DC432GLL2"
hosts = ["chatgpt.com", "auth.openai.com"]
```

`chatgpt.com` is the model, through its backend API, for a ChatGPT sign-in. `auth.openai.com` is where Codex renews
that sign-in; the renewal has not been seen under the hook yet.

## Checking it

[`../eval/run.sh`](../eval/run.sh) runs a decider over the events in [`../eval/events/`](../eval/events/) the way
the daemon runs a program hook, with the hook above (the instructions from the repository), and compares each
answer with [`../eval/cases.json`](../eval/cases.json):

```console
$ integrations/eval/run.sh --agent codex
```

It uses the sign-in in `~/.config/blackice/agent/.codex`; `CODEX_HOME=dir` picks another one, and `MODEL=name`
another model.

On 5 November 2026, with Codex 0.166.0 and a personal sign-in (`CODEX_HOME=~/.codex`, whose own `AGENTS.md` was in
the prompt, as above), one run with `gpt-6-luna` and one with `gpt-6.1-sol` both came out 23 for 23:

| Model | As expected | Median | p90 | Slowest |
| --- | --- | --- | --- | --- |
| `gpt-6-luna` | 23/23 | 4.6 s | 5.8 s | 8.4 s |
| `gpt-6.1-sol` | 23/23 | 6.6 s | 11.8 s | 22.1 s |

- Every decision ran one command, `cat event.json notes.md`, and every reply was the two lines asked for, the
  verdict last.
- The seven apps reaching their own services were approved. `gpt-6-luna` gave the five vendor-signed ones 12 hours
  and the cdhash-named Homebrew `gh` and `ssh` to a Tailscale address 30 minutes; `gpt-6.1-sol` gave 24, 12 and 1
  hours.
- The lookalike hosts, the binaries in `~/Downloads`, `/tmp` and a hidden cache directory, the bare and public
  addresses, the odd ports, the event with no host and the four with instructions in the host or the path were
  denied, and the injected `touch` never ran.

So the hook uses `gpt-6-luna`: as accurate on these cases, and faster. Two runs show the instructions can work,
not that they always will.

## What stays exposed

- **Its home.** Codex reads `AGENTS.md` (and `AGENTS.override.md`) from `CODEX_HOME` as global instructions
  whatever the flags say, and lists the skills in `CODEX_HOME/skills`. Any program running as you can write one
  there, next to the instructions blackice writes, and through it steer what Codex answers, as with fx's skills.
  `agent connect` writes neither, and the signature check covers Codex itself, not its home.
- **Reading.** The sandbox lets Codex's commands read the event's directory and the system's own files
  (`:minimal`), `/etc` and `/tmp` among them. From a directory where the daemon makes them, in your `TMPDIR`, a
  read of your home, of your `TMPDIR` and of another event's directory was refused. What it reads goes to the
  model.

## Open questions

- **Codex upgrades.** The permission profile, `model_instructions_file` and the feature names are recent. An
  upgrade that renames one stops the hook (`--strict-config`) or, for a feature, may turn something back on. Run
  the eval again after upgrading.
- **Usage limits.** A plan that hits its limit answers with an error, and every connection is denied at its
  deadline until the limit resets.
- **Several at once.** The daemon runs up to 4 hooks at once, so up to 4 Codex processes share one sign-in and
  renew it together.
