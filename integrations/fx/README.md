# fx integration (draft)

A skill that lets [fx](https://github.com/vercel-labs/fx) decide netshield's ask-mode
connections. Nothing here works end to end yet: `netshield approve` and `netshield deny`
exist only as argument parsing until the network extension is built (phase 2), and hooks
arrive in phase 3.

- [`skills/netshield/SKILL.md`](skills/netshield/SKILL.md): what the agent reads, what it
  weighs and how it answers.
- [`skills/netshield/sample-event.json`](skills/netshield/sample-event.json): an event in
  the format `HookEvent` encodes. A unit test in `macos/` decodes it, so the two stay in step.

## Installing the skill

fx looks for skills in `~/.fx/skills`, `~/.agents/skills` and `~/.claude/skills`, and in a
workspace's `.fx/skills`, `.agents/skills`, `.claude/skills` and `skills/`. For example:

```console
$ mkdir -p ~/.fx/skills && ln -s "$PWD/integrations/fx/skills/netshield" ~/.fx/skills/netshield
```

## The hook

fx v0.0.16 runs one request with `fx ask`; it has no `-p` flag. The hook in
`netshield.toml` would be:

```toml
[[hook]]
on = "connection"
run = 'fx ask "Use the netshield skill to decide whether to approve the pending connection"'
```

## Open questions

- **How the event reaches the agent.** The design gives hooks the event as JSON on stdin.
  `fx ask` reads stdin as the prompt only when no prompt arguments are given, so with the
  hook above the event would not reach the model. The skill assumes the daemon also writes
  the event to a file only the user can read and sets `NETSHIELD_EVENT_FILE` to its path.
  That is a proposal for phase 3, not a decision.
- **Permissions.** The agent has to run `netshield approve` and `netshield deny` without a
  prompt, and nothing else. How to grant exactly that in fx's permission settings is not
  worked out yet.
- **The agent's own network.** fx needs to reach its model provider. In ask mode that
  connection must be covered by a fixed rule bound to fx's signature, or fx waits on its own
  approval (see `docs/plan.md`, open problems).
