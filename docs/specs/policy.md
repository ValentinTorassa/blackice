---
id: policy
title: Policy
owner: lead
stage: poc
paths: src/core/policy.zig, examples/agent.json
cases: P0-01, P0-02, P0-03
depends:
---

# Policy

## What and why

A policy is a small JSON file that says where a scope may connect: nowhere, anywhere public, or only to the
names and networks it lists. blackice reads it before the command starts and every enforcement point (the
proxy, the kernel rules, the relay) asks it the same questions. If the file is wrong in any way, blackice
refuses it instead of guessing, so a typo can never open more access than the author meant. Every decision
names the rule that made it, so a person can see why a connection was allowed or refused.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| policy.R1 | If a policy file is not valid JSON, has a field blackice does not know, or names a version other than `blackice.policy/v0`, blackice shall refuse it, say which field or value is at fault, and exit non-zero without starting any command. | P0-01 |
| policy.R2 | If an allow entry is an IP address, uses `*` anywhere except a leading `*.`, or is not a valid host name, blackice shall refuse the policy. | P0-01 |
| policy.R3 | When the mode is `deny-all`, blackice shall refuse every destination, by name or by address. | P0-02 |
| policy.R4 | When the mode is `allowlist`, blackice shall allow a name only if an entry matches it: `example.com` matches only `example.com`, and `*.example.com` matches names below `example.com` but not `example.com` itself. Names are compared without case and without a trailing dot. | P0-03 |
| policy.R5 | When an allowed name resolves to an address in a denied subnet, or to a loopback, private, link-local, CGNAT, multicast or reserved address that no allowed subnet covers, blackice shall refuse that address. | P0-02 |
| policy.R6 | When a destination is written as an IP address, blackice shall allow it only if an allowed subnet covers it, or, in `allow-all` mode, if it is a public address. A denied subnet always refuses. | P0-03 |
| policy.R7 | blackice shall give every decision a stable reason code and, when a policy entry decided it, that entry exactly as written in the file. | P0-09 |
| policy.R8 | blackice shall identify each loaded policy by a digest of its exact bytes, and carry that identifier in every receipt of the scope. | P0-09 |

## Design

The policy is data, not code: there are no conditions, no includes and no defaults that widen access. Three
modes cover the proof of concept. Names and networks are checked in two steps: first the name the program
asked for, then every address that name resolves to. The second step stops an allowed name that points at
`127.0.0.1` or a home router from reaching local services.

**Technical.**

- File format:

  ```json
  {
    "version": "blackice.policy/v0",
    "network": {
      "mode": "allowlist",
      "allow": ["example.com", "*.npmjs.org"],
      "subnets": { "allow": ["10.20.0.0/16"], "deny": ["203.0.113.0/24"] }
    }
  }
  ```

- `mode`: `deny-all`, `allow-all` or `allowlist`. `allow`, `subnets.allow` and `subnets.deny` are optional.
- Parsing uses the Zig standard library JSON parser with unknown fields rejected.
- Evaluation (`src/core/policy.zig`): `checkHost` for a name, `checkResolved` for each address an allowed
  name resolves to, `checkLiteral` for a destination written as an address. Order inside `checkResolved` and
  `checkLiteral`: denied subnet, then allowed subnet, then the local/private test.
- Reason codes: `allowed_by_rule`, `allowed_by_mode`, `allowed_subnet`, `public_address`,
  `no_matching_rule`, `mode_deny_all`, `ip_literal_needs_subnet`, `denied_subnet`,
  `local_or_private_address`, `invalid_host`. Renaming one is a contract change.
- Policy identifier: the first 12 hex digits of the SHA-256 of the file bytes.
- `blackice policy check FILE` loads a policy and prints its mode, counts and identifier.
- Not in v0: ports and protocols as policy dimensions, nested scopes and a host ceiling (a child scope can
  only narrow its parent), observe mode, policy updates while a scope runs (except grants), and any
  Sandbox-specific field (see [sandbox-import](sandbox-import.md)).

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Parse policy v0 and reject unknown fields, versions and modes | lead | done | |
| Name, resolved-address and IP-literal checks with reason codes | lead | done | |
| `blackice policy check FILE` | lead | done | |
| Shared test vectors that every enforcement point runs against the same verdicts | codex | todo | |
| docs/policy.md for users | codex | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| policy.R1, policy.R2 | test | `zig build test`, src/core/policy.zig: "invalid policies fail closed" | 11/11 passed at 0c43c6f, Zig 0.17.0, Linux x86_64 |
| policy.R3 | test | `zig build test`, src/core/policy.zig: "deny-all and allow-all" | same run |
| policy.R4 | test | `zig build test`, src/core/policy.zig: "allowlist: exact and wildcard names" | same run |
| policy.R5 | test | `zig build test`, src/core/policy.zig: "resolved addresses: local and private are refused, subnets decide" | same run |
| policy.R6 | test | `zig build test`, src/core/policy.zig: "IP literals need an allowed subnet in allowlist mode" | same run |

## Terms

policy, scope, receipt, reason code, policy digest, allowlist, subnet, CIDR, DNS
