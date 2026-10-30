---
id: fx-relay
title: Relay and fx integration
owner: lead, codex-network
stage: poc
paths: src/relay/, src/fx/
cases: P0-02, P0-06, P0-07, P0-09
depends: scope-core, proxy, receipts, macos-task-scope, linux-task-scope
---

# Relay and fx integration

## What and why

[fx](https://github.com/vercel-labs/fx) is a coding agent that runs commands on the machine: tests, builds,
installs. `blackice run -- fx` puts fx and everything it starts inside one task scope, without changing fx.
fx still needs its model, and the model needs a key. The relay is a small endpoint outside the scope that fx
talks to instead of the provider: it adds the key on the way out, so the key never enters the scope. Without
the relay, the key would sit in fx's environment, where any command fx runs could read it and send it
anywhere the policy allows.

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
| fx-relay.R8 | When blackice prepares fx for a scope, it shall give fx its own home directory with a configuration that points one provider at `http://127.0.0.1:<relay port>/v1` with no authentication, using the file modes fx requires (directory `0700`, settings file `0600`). It shall not read or write the user's own fx configuration. | P0-07 |
| fx-relay.R9 | When fx runs inside a task scope, fx and every process it starts shall reach the network only through the scope's proxy and relay. A direct connection from a tool to any other address shall be refused by the operating system, and fx shall still complete its run. | P0-07 |
| fx-relay.R10 | If the relay stops or the gateway cannot be reached, fx's model calls shall fail and the scope's policy shall stay in force: nothing falls back to a direct connection. | P0-06 |

## Design

fx runs entirely inside the task scope. Its model traffic goes to the relay on a loopback port, and every
command it starts reaches the network only through the scope's proxy. The relay and the proxy both run
outside the scope, in the blackice process, and are the only two loopback ports the scope may open.

The relay is deliberately narrow: one gateway, one API path, a list of models and two caps. It moves the key
out of the scope. It does not decide what content may be sent to the model.

**Technical.**

- Gateway: an OpenAI-compatible chat-completions endpoint, such as AI Gateway. The relay reads the key from
  stdin once at start; on the demo machines it comes from a password manager and is piped straight in.
- fx configuration: a configured provider with protocol `openai-chat-completions`, `base_url` on loopback
  (fx accepts `http://` only for `127.0.0.1`, `[::1]` and `localhost`) and `auth: none`. fx ignores its user
  settings unless the private state directory is `0700` and `settings.json` is `0600`.
- Why a relay and not the proxy: fx's model client does not use proxy environment variables, so model
  traffic must reach a loopback endpoint directly.
- Integration level for the proof of concept (L0): fx and all of its tools share one scope and one policy.
- Tested target: fx v0.0.16. Every evidence entry names the fx release tag and commit used.
- Limits:
  - A tool inside the scope can call the relay too. It can send any content to the allowed model endpoint and
    spend the scope's request cap. The caps bound the spend; they do not stop disclosure to that endpoint.
  - The key is protected from the scope, not from other processes of the same user running outside every
    scope. Credential storage needs its own boundary.
  - One scope for fx and its tools: no per-tool isolation and no trusted link between a tool call and its
    connections. That needs a launch hook in fx and is future work.
  - fx features that need other destinations (web fetch, MCP servers, skill installs, upgrades, usage
    reporting) fail unless the policy allows them.
  - In fx's default auto mode, recognized project commands (tests, builds, local installs) run without review.
    The code inside them is never reviewed, which is where a network boundary adds the most. Reviews of other
    commands go to the model through the same relay and count against the caps.
  - Gateway features that differ between its native API and chat-completions may behave differently.
  - On macOS, the equivalent of R2 is not chosen yet.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Install fx v0.0.16 from the verified release on the Linux and macOS test machines | valen | done | |
| Feasibility probes of the L0 shape on Linux and macOS, with a scripted model | lead | done | |
| Relay: loopback endpoint, key on stdin, forwarding to the gateway | codex-network | todo | |
| Relay limits: model allow list, size cap, request cap, one receipt per call | codex-network | todo | |
| Relay process hardening: not dumpable on Linux; macOS equivalent | codex-network | todo | |
| fx setup for a scope: isolated home, configured provider, file modes | lead | todo | |
| End-to-end run inside a real task scope on each OS, scripted model first | lead | todo | |
| Real model through the gateway, key piped from the password manager | lead | todo | |
| Evidence entries for P0-07 on Linux and macOS, naming the fx tag and commit | lead | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| fx-relay.R8, fx-relay.R9 | probe | - | Linux, 30 Oct: fx v0.0.16 in an empty network namespace with a scripted model on loopback and a stand-in proxy. No Authorization header reached the model; a direct request from a tool failed to resolve; the same request through the stand-in proxy arrived as CONNECT with the host name; fx exited 0. No blackice code. |
| fx-relay.R8, fx-relay.R9 | probe | - | macOS 27.0.1, 30 Oct, SIP off and then on: the same run under a Seatbelt profile allowing two loopback ports. Same results. No blackice code. |

## Terms

fx, fx auto mode, L0, task scope, relay, AI Gateway, credentials brokering, configured provider, proxy,
receipt, reason code, Seatbelt, SIP, loopback
