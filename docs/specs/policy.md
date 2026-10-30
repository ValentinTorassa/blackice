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
| policy.R1 | If a policy file is not valid JSON, has a field blackice does not know, repeats a key, or names a version other than `blackice.policy/v0`, blackice shall refuse it, say which field or value is at fault, and exit non-zero without starting any command. | P0-01 |
| policy.R2 | If an allow entry is an IP address, uses `*` anywhere except a leading `*.`, or is not a valid host name, blackice shall refuse the policy. | P0-01 |
| policy.R3 | When the mode is `deny-all`, blackice shall refuse every destination, by name or by address. | P0-02 |
| policy.R4 | When the mode is `allowlist`, blackice shall allow a name only if an entry matches it: `example.com` matches only `example.com`, and `*.example.com` matches names below `example.com` but not `example.com` itself. Names are compared without case and without a trailing dot. | P0-03 |
| policy.R5 | When an allowed name resolves to an address in a denied subnet, or to a loopback, private, link-local, CGNAT, multicast or reserved address that no allowed subnet covers, blackice shall refuse that address. | P0-02 |
| policy.R6 | When a destination is written as an IP address, blackice shall allow it only if an allowed subnet covers it, or, in `allow-all` mode, if it is a public address. A denied subnet always refuses. | P0-03 |
| policy.R7 | blackice shall give every decision a stable reason code and, when a policy entry decided it, that entry exactly as written in the file. | P0-09 |
| policy.R8 | blackice shall identify each loaded policy by a digest of its exact bytes, and carry that identifier in every receipt of the scope. | P0-09 |
| policy.R9 | When a destination port is not in `network.ports` (80 and 443 when the field is absent), blackice shall refuse it with reason `port_not_allowed`, even if the host is allowed. | P0-03 |
| policy.R10 | If a host name, in the policy or in a request, has a last label that is all digits or a `0x` number (for example `127.1`, `2130706433`, `0x7f000001`), blackice shall treat it as invalid (`invalid_host`), because the system resolver would turn it into an address. | P0-02 |
| policy.R11 | When an IPv6 address carries an IPv4 address (`::ffff:0:0/96`, `64:ff9b::/96`, `::/96`), blackice shall judge it by that IPv4 address; `64:ff9b:1::/48` and `2002::/16` count as local unless an allowed subnet covers them. | P0-02 |

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
      "subnets": { "allow": ["10.20.0.0/16"], "deny": ["203.0.113.0/24"] },
      "ports": [443]
    }
  }
  ```

- `mode`: `deny-all`, `allow-all` or `allowlist`. `allow`, `subnets.allow`, `subnets.deny` and `ports` are
  optional. Without `ports`, only 80 and 443 are allowed.
- Parsing uses the Zig standard library JSON parser with unknown fields rejected.
- Evaluation (`src/core/policy.zig`): `checkHost` for a name, `checkResolved` for each address an allowed
  name resolves to, `checkLiteral` for a destination written as an address, and `checkPort` for every
  destination port. Order inside `checkResolved` and
  `checkLiteral`: denied subnet, then allowed subnet, then the local/private test.
- Reason codes: `allowed_by_rule`, `allowed_by_mode`, `allowed_subnet`, `public_address`,
  `no_matching_rule`, `mode_deny_all`, `ip_literal_needs_subnet`, `denied_subnet`,
  `local_or_private_address`, `port_not_allowed`, `invalid_host`. Renaming one is a contract change.
- Policy identifier: the first 12 hex digits of the SHA-256 of the file bytes.
- `blackice policy check FILE` loads a policy and prints its mode, counts and identifier.
- Not in v0: protocols as a policy dimension, nested scopes and a host ceiling (a child scope can
  only narrow its parent), observe mode, policy updates while a scope runs (except grants), and any
  Sandbox-specific field (see [sandbox-import](sandbox-import.md)).

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| Parse policy v0 and reject unknown fields, versions and modes | lead | done | |
| Name, resolved-address and IP-literal checks with reason codes | lead | done | |
| `blackice policy check FILE` | lead | done | |
| `network.ports` (default 80 and 443) and `checkPort` | lead | todo | |
| Shared test vectors that every enforcement point runs against the same verdicts | codex | todo | |
| docs/policy.md for users | codex | done | |
| Numeric names and `0x` names refused (R10) | lead | todo | |
| IPv4-embedded IPv6 judged by its IPv4 address, in requests and in policy subnets (R11) | lead | todo | |
| Repeated keys refused (R1) | lead | todo | |
| Error messages keep their own copy of the rejected text, and a parsed policy owns all its strings | lead | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| policy.R1, policy.R2 | test | `zig build test`, src/core/policy.zig: "invalid policies fail closed" | 11/11 passed at 0c43c6f, Zig 0.17.0, Linux x86_64. Repeated keys are not in this test yet |
| policy.R3 | test | `zig build test`, src/core/policy.zig: "deny-all and allow-all" | same run |
| policy.R4 | test | `zig build test`, src/core/policy.zig: "allowlist: exact and wildcard names" | same run |
| policy.R5 | test | `zig build test`, src/core/policy.zig: "resolved addresses: local and private are refused, subnets decide" | same run |
| policy.R6 | test | `zig build test`, src/core/policy.zig: "IP literals need an allowed subnet in allowlist mode" | same run |

## Terms

policy, scope, receipt, reason code, policy digest, allowlist, subnet, CIDR, DNS
