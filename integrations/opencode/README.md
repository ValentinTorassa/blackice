# opencode integration (draft)

**The short way:** `blackice agent connect opencode` does everything on this page in one command, and tries opencode
on a sample connection before it changes `blackice.toml`. The rest of this page is what it does, by hand, and why.

[opencode](https://opencode.ai/docs) decides blackice's ask-mode connections with `opencode run`, signed in to a
provider you pick when you connect it. It reads the event with its read tool, weighs it, and ends its reply with one
verdict line, which the daemon reads from the hook's stdout: `approve 12h`, `approve 30m` or `deny`. With stdout not
a terminal, `opencode run` prints its reply there; its progress and errors go to stderr.

- [`instructions.md`](instructions.md): its whole system prompt. What it reads, what it weighs and how it answers,
  in step with fx's skill and the Claude Code and Codex instructions. blackice ships a copy inside its binary (a
  test in `macos/` fails when the two differ; `macos/scripts/agent-instructions.sh` writes it).

## The provider

`agent connect opencode` asks which provider opencode decides with, and the rule it adds names that provider's
hosts and no other. `--model PROVIDER/MODEL` picks one without the list. Connecting it again with another provider
adds that provider's hosts and leaves the old provider's in the rule; remove those by hand if you want the rule
narrow.

| Provider | `--model` it writes | Hosts in the rule |
| --- | --- | --- |
| OpenAI, a ChatGPT plan or an API key | `openai/gpt-6-luna` | `chatgpt.com`, `auth.openai.com`, `api.openai.com` |
| Z.AI Coding Plan | `zai-coding-plan/glm-5.3-flash` | `api.z.ai` |
| OpenCode Go | `opencode-go/gpt-6-luna` | `opencode.ai` |
| MiniMax Token Plan | `minimax-coding-plan/MiniMax-M3.1-Flash` | `api.minimax.io` |
| OpenRouter | `openrouter/openai/gpt-6-luna` | `openrouter.ai` |
| Anthropic, an API key | `anthropic/claude-haiku-5-5` | `api.anthropic.com` |

The models are each provider's small ones: the coding plans' are part of the plan, the others cost $0.10 and $0.50
per million tokens in and out in models.dev's list on 5 November 2026. OpenAI is first in the list, the one Enter
picks: in the eval below it decided every case as expected and was the fastest, while Z.AI's `glm-5.3-flash` took
three times as long and approved one connection it should have denied.

On 5 November 2026, opencode 2.2.5 decided one event with each provider, with its model list fetch off and a key that
was not one, through a local proxy that logged every host it asked for. Each reached only its host in the table, and
stopped at the provider's refusal. For OpenAI that was `api.openai.com`, with an API key. A ChatGPT sign-in goes to
`chatgpt.com` (opencode 2.2.5 holds its `backend-api/codex` address) and is renewed at `auth.openai.com`. Later
that day, two decisions with a ChatGPT sign-in, through the same proxy, reached `chatgpt.com` and nothing else; the
sign-in was fresh, so its renewal at `auth.openai.com` was not seen. One with the Z.AI Coding Plan reached `api.z.ai`
and nothing else.

## The hook

The hook `agent connect` writes, for a home at `/Users/me`, opencode's installer's `opencode` and OpenAI:

```toml
[[hook]]
on = "connection"
program = "/Users/me/.opencode/bin/opencode"
app = "opencode"
team = "5NZ4Q7NXJ4"
args = ["run", "--standalone", "--agent", "blackice", "--model", "openai/gpt-6-luna", "Decide whether to approve the pending blackice connection in event.json."]
env = ["HOME=/Users/me/.config/blackice/agent/.opencode", "OPENCODE_CONFIG_CONTENT={…}", "OPENCODE_DISABLE_AUTOUPDATE=1", "OPENCODE_DISABLE_CLAUDE_CODE=1", "OPENCODE_DISABLE_MODELS_FETCH=1", "OPENCODE_DISABLE_PROJECT_CONFIG=1", "XDG_CONFIG_HOME=."]
stdin = "none"
instructions = "opencode"
```

`program` is the `opencode` it found on `PATH`, in the usual folders or in `~/.opencode/bin`, where opencode's
installer (`curl -fsSL https://opencode.ai/install | bash`) puts it. `app` and `team` are read from that binary
(`codesign -dv`: `Identifier=opencode`, `TeamIdentifier=5NZ4Q7NXJ4`, Anomaly Innovations), and the daemon starts it
only when the running code has them. `OPENCODE_CONFIG_CONTENT` holds, on one line:

```json
{"agent": {"blackice": {"mode": "primary", "prompt": "{file:./instructions.md}", "steps": 4,
                        "permission": {"*": "deny", "read": "allow", "bash": "deny", "edit": "deny", "…": "deny"}}},
 "autoupdate": false,
 "permission": {"*": "deny", "read": "allow", "bash": "deny", "edit": "deny", "…": "deny"},
 "share": "disabled"}
```

Checked against opencode 2.2.5:

- **`--agent blackice`** with **`"prompt": "{file:./instructions.md}"`** and **`instructions = "opencode"`**: before
  opencode starts, the daemon writes the instructions, from blackice itself, as `instructions.md` in the event's
  directory, its working directory, and they are the agent's whole system prompt, in place of opencode's own. The
  path is relative to that directory. In the eval below, opencode read `notes.md` and `event.json`, as the
  instructions say, and called no other tool.
- **`permission`**: the read tool and no other. `"*"` comes first, since the last rule that matches wins, and every
  tool is named as well: a rule for one in a configuration file of its home would otherwise stay. The same rules
  are set for the agent, whose rules come before the global ones. `external_directory` is denied, so a read outside
  the event's directory is refused.
- **`OPENCODE_CONFIG_CONTENT`**: opencode reads it after its global and project files, so what it sets wins.
- **`XDG_CONFIG_HOME=.`**: opencode's global configuration folder is `opencode/` in its working directory, which it
  creates, empty. For the hook that is the event's new private directory, which the daemon removes afterwards. So no
  `opencode.json`, `AGENTS.md`, plugin, command or skill that a program wrote into a folder of yours is loaded.
  (opencode stops when it cannot create that folder, so it cannot be a folder nobody can write, such as `/var/empty`.)
- **`OPENCODE_DISABLE_PROJECT_CONFIG=1`**: no `opencode.json` or `AGENTS.md` from the folders above the event's.
  **`OPENCODE_DISABLE_CLAUDE_CODE=1`**: nothing from `~/.claude`.
- **`OPENCODE_DISABLE_AUTOUPDATE=1`**, **`"autoupdate": false`**, **`OPENCODE_DISABLE_MODELS_FETCH=1`**,
  **`"share": "disabled"`**: no update check, no model list from `models.opencode.ai`, no sharing. opencode knows the
  models of a provider it is signed in to without that list. Through the proxy, a decision reached only its provider.
- **`--standalone`**: opencode runs its own server for the request. Without it, `opencode run` goes through the
  background service that opencode shares between its commands, which runs with your own `HOME`.
- **`"steps": 4`**: a decision reads two files and answers; a run that goes on past four steps ends without an answer.
- **`stdin = "none"`**: the event reaches opencode only as the file it reads, as data.

## Signing in

`HOME` gives opencode a home of its own, `~/.config/blackice/agent/.opencode`, apart from yours. opencode 2.2.5 keeps
its sign-ins in its database there (`.local/share/opencode/opencode.db`), not in `auth.json`.

```console
$ export HOME="$HOME/.config/blackice/agent/.opencode"   # in a shell of its own
$ opencode auth login --standalone openai
$ opencode auth list --standalone
```

`agent connect` runs the same, and counts the sign-in when `opencode auth list --format json` shows one stored for
that provider. A key in a variable of your shell (`ZHIPU_API_KEY`, `OPENAI_API_KEY`) shows there as `env`, and does
not count: the hook gets none of the shell's variables. With no sign-in, opencode 2.2.5 says
`Model unavailable: PROVIDER/MODEL`.

## Its own network

In ask mode, opencode's own connections must be covered by a rule bound to its signature, or it waits on its own
approval:

```toml
[[allow]]
app = "opencode"
team = "5NZ4Q7NXJ4"
hosts = ["chatgpt.com", "auth.openai.com", "api.openai.com"]
```

## Checking it

[`../eval/run.sh`](../eval/run.sh) runs a decider over the events in [`../eval/events/`](../eval/events/) the way
the daemon runs a program hook, with the hook above (the instructions from the repository), and compares each
answer with [`../eval/cases.json`](../eval/cases.json):

```console
$ integrations/eval/run.sh --agent opencode
```

It uses the sign-in in `~/.config/blackice/agent/.opencode`; `OPENCODE_HOME=dir` picks another `HOME`, and
`MODEL=provider/name` another model.

On 5 November 2026, with opencode 2.2.5, the sign-ins in your own home (`OPENCODE_HOME=$HOME`) and the filter in
accept-all:

- `openai/gpt-6-luna`, with a ChatGPT plan: the 23 cases as expected, in 3.9 s at the median and 5.5 s at the 90th
  percentile. A decision took about 3,200 tokens in, 1,500 more read from the cache, and 85 out.
- `zai-coding-plan/glm-5.3-flash`: 22 of the 23, in 12.8 s at the median and 17.5 s at the 90th percentile. It
  approved case 15, Slack reaching `slack.com` on port 6667, for 30 minutes, and for 24 hours when that case ran
  again; fx, Claude Code, Codex and opencode with `gpt-6-luna` deny it. A decision took about 2,700 tokens in, 2,400
  read from the cache, and 260 out (three decisions measured).

In each of the 46 decisions opencode read `notes.md` (there was none) and `event.json` and called no other tool, and
no injection case got it to do anything else. Three other providers signed in there failed every event at once, with
exit 1 and no answer: OpenCode Go (`This API key has expired`), xAI (its refresh token refused; xAI is not in
`agent connect`'s list) and MiniMax (`insufficient balance`). `agent connect` tries a sample connection before it
writes the hook, so it stops at these; a sign-in that lapses later fails each event the same way.

## What stays exposed

- **Its data folder.** The sign-in and every decision's session are in the database in its home, readable and
  writable by any program running as you. The instructions and the configuration come with each event, not from
  there. The database also has a table of permissions; whether a row written there could undo the hook's denials
  has not been checked.
- **Its cache.** `~/.config/blackice/agent/.opencode/.cache/opencode` holds what opencode downloads for itself; with
  no plugin, formatter or language server configured, nothing was seen there but an empty `bin` folder.
- **Reading.** The read tool reads the event's directory. A read outside it is refused by `external_directory`;
  no model tried one in the eval. What it reads goes to the model.

## Open questions

- **opencode upgrades.** `OPENCODE_CONFIG_CONTENT`, the permission names, `XDG_CONFIG_HOME` and `--standalone` are
  opencode 2.2.5's. An upgrade that renames one may turn something back on. Run the eval again after upgrading.
- **Usage limits.** A plan that hits its limit answers with an error, and every connection is denied at its
  deadline until the limit resets. The same goes for a key that expires or a balance that runs out.
- **Several at once.** The daemon runs up to 4 hooks at once, so up to 4 opencode processes share one database.
