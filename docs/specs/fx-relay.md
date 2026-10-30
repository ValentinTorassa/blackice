---
id: fx-relay
title: fx integration and relay
owner: lead, network
stage: poc
paths: integrations/fx/, src/fx/, src/relay/
cases: P0-01, P0-02, P0-06, P0-07, P0-09
depends: scope-core, proxy, receipts, macos-task-scope, linux-task-scope
---

# fx integration and relay

## What and why

[fx](https://github.com/vercel-labs/fx) is a coding agent that runs commands on the machine: tests, builds,
installs. In its default auto mode, familiar project commands run with no review, so nobody has looked at the
code inside them. blackice works with fx in two ways. In the main mode, a small declared patch to fx's
`PreToolUse` hook runs every command fx launches in its own blackice scope, with its own policy and receipts,
while fx itself stays outside. In the fallback mode (L0), all of fx runs inside one scope without any change to
fx; then fx reaches its model through the relay, a small endpoint outside the scope that adds the key on the way
out, so the key never enters the scope.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| fx-relay.R1 | blackice shall accept the gateway key only on standard input. It shall offer no flag, environment variable or file option for it, and the key shall not appear in the scope's environment, arguments, receipts or state directory. | P0-09 |
| fx-relay.R2 | When the relay starts on Linux, it shall mark its process as not dumpable, so that core dumps and same-user debuggers cannot read the key from its memory. | P0-07 |
| fx-relay.R3 | The relay shall listen only on `127.0.0.1` on a random port, and shall forward only `POST /v1/chat/completions` to the one configured gateway URL, adding the key. Any other method, path or target shall be refused with an error and a receipt. | P0-07 |
| fx-relay.R4 | When a request names a model that is not on the scope's model allow list, the relay shall refuse it without contacting the gateway. | P0-07 |
| fx-relay.R5 | If a request body is larger than the size cap, or the scope has used its request cap, the relay shall refuse it without contacting the gateway. | P0-07 |
| fx-relay.R6 | The relay shall write one receipt per call with the scope, the model, the verdict, a reason code and the bytes sent and received. It shall never write prompt or response content or the key. | P0-09 |
| fx-relay.R7 | If a process in another task scope tries to connect to this scope's relay port, the operating system shall refuse the connection. | P0-02 |
| fx-relay.R8 | In L0 mode, when blackice prepares fx for a scope, it shall give fx its own home directory with a configuration that points one provider at `http://127.0.0.1:<relay port>/v1` with no authentication, using the file modes fx requires (directory `0700`, settings file `0600`). It shall not read or write the user's own fx configuration. | P0-07 |
| fx-relay.R9 | In L0 mode, when fx runs inside a task scope, fx and every process it starts shall reach the network only through the scope's proxy and relay. A direct connection from a tool to any other address shall be refused by the operating system, and fx shall still complete its run. | P0-07 |
| fx-relay.R10 | If the relay stops or the gateway cannot be reached, fx's model calls shall fail and the scope's policy shall stay in force: nothing falls back to a direct connection. | P0-06 |
| fx-relay.R11 | When the fx hook is installed and fx runs a command through its shell tool, the command shall run as `blackice run --policy <file> -- <command>`, in its own scope, with its own receipts. | P0-07 |
| fx-relay.R12 | When the hook starts a command, blackice shall give the scope a scrubbed environment, so secrets in fx's environment do not pass into the scope. | P0-07 |
| fx-relay.R13 | If the hook cannot start blackice, or blackice cannot create the scope, the command shall not run: the tool call fails instead of running unconfined. | P0-01 |
| fx-relay.R14 | blackice shall ship the hook as a declared patch under `integrations/fx/` that names the fx release tag and commit it applies to, so anyone can read exactly what it changes in fx. | P0-07 |

## Design

**Main mode: one scope per command.** The fx hook rewrites each shell tool call so the command runs under
`blackice run`. Each command gets a fresh scope, the policy file named in the hook's settings, a scrubbed
environment and its own receipts. fx and its model traffic stay outside every scope, so this mode needs no
relay. The patch is small, lives in the repo, and names the exact fx version it applies to; fx is Apache-2.0.

**Fallback mode: L0.** `blackice run --policy FILE -- fx` puts fx and everything it starts in one scope. fx's
model traffic then goes to the relay on a loopback port, and its commands reach the network only through the
proxy. The relay is deliberately narrow: one gateway, one API path, a list of models and two caps. It moves the
key out of the scope; it does not decide what content may be sent to the model.

**Technical.**

- Hook: a builtin `PreToolUse` handler added to fx by the patch in `integrations/fx/`. For the shell tool it
  rewrites the call to `blackice run --policy <file> -- <command>`. Other fx tools are not rewritten.
- Gateway (L0): an OpenAI-compatible chat-completions endpoint, such as AI Gateway. The relay reads the key from
  stdin once at start; on the demo machines it comes from a password manager and is piped straight in. Relay
  settings are `blackice run` flags.
- fx configuration (L0): a configured provider with protocol `openai-chat-completions`, `base_url` on loopback
  (fx accepts `http://` only for `127.0.0.1`, `[::1]` and `localhost`) and `auth: none`. fx ignores its user
  settings unless the private state directory is `0700` and `settings.json` is `0600`.
- Why a relay and not the proxy: fx's model client does not use proxy environment variables, so model
  traffic must reach a loopback endpoint directly.
- Tested target: fx v0.0.16. Every evidence entry names the fx release tag and commit used, and the mode.
- Limits:
  - Main mode: fx itself is not confined. Its own network features (web fetch, MCP servers, skill installs,
    upgrades) run as they do today. The hook confines the commands fx launches through its shell tool.
  - Main mode: the hook is a patch, not an fx feature. Until fx offers a supported launch hook, each fx release
    needs the patch checked again.
  - L0: a tool inside the scope can call the relay too. It can send any content to the allowed model endpoint
    and spend the scope's request cap. The caps bound the spend; they do not stop disclosure to that endpoint.
  - L0: the relay port has no authentication, so a process of the same user outside every scope can reach it.
  - L0: one scope for fx and its tools, so no per-tool isolation; fx features that need other destinations fail
    unless the policy allows them.
  - The key is protected from the scope, not from other processes of the same user running outside every
    scope. Credential storage needs its own boundary.
  - Gateway features that differ between its native API and chat-completions may behave differently.
  - On macOS, the equivalent of R2 is not chosen yet.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Install fx v0.0.16 from the verified release on the Linux and macOS test machines | valen | done | |
| Feasibility probes of the L0 shape on Linux and macOS, with a scripted model | lead | done | |
| fx hook patch: builtin `PreToolUse` handler that wraps shell commands in `blackice run` | lead | todo | |
| Scrubbed environment for scopes started by the hook | lead | todo | |
| Relay: loopback endpoint, key on stdin, forwarding to the gateway | network | todo | waits for: the proxy, which comes first |
| Relay limits: model allow list, size cap, request cap, one receipt per call | network | todo | |
| Relay process hardening: not dumpable on Linux; macOS equivalent | network | todo | |
| L0 fx setup for a scope: isolated home, configured provider, file modes | lead | todo | |
| End-to-end run of each mode on each OS, scripted model first | lead | todo | |
| Real model through the gateway, key piped from the password manager | lead | todo | |
| Evidence entries for P0-07 on Linux and macOS, naming the fx tag, commit and mode | lead | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| fx-relay.R8, fx-relay.R9 | probe | - | Linux, 30 Oct: fx v0.0.16 in an empty network namespace with a scripted model on loopback and a stand-in proxy. No Authorization header reached the model; a direct request from a tool failed to resolve; the same request through the stand-in proxy arrived as CONNECT with the host name; fx exited 0. No blackice code. |
| fx-relay.R8, fx-relay.R9 | probe | - | macOS 27.0.1, 30 Oct, SIP off and then on: the same run under a Seatbelt profile allowing two loopback ports. Same results. No blackice code. |

## Terms

fx, fx auto mode, fx hook, L0, task scope, relay, AI Gateway, credentials brokering, configured provider,
proxy, receipt, reason code, Seatbelt, SIP, loopback
