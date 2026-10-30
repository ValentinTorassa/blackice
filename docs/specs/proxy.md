---
id: proxy
title: Proxy
owner: codex-network
stage: poc
paths: src/proxy/
cases: P0-02, P0-03
depends: policy, receipts, scope-core
---

# Proxy

## What and why

Operating system sandboxes can block a program's network access, but most of them cannot say "allow
`registry.npmjs.org`, refuse everything else". The proxy fills that gap. Each scope gets its own small proxy
that runs outside the scope, on the local machine only. The scoped command can reach nothing but this proxy;
the proxy checks the name the command asked for against the policy, looks the name up itself, and connects only
if both the name and the address it found are allowed. Every answer it gives is written as a receipt.

## Requirements

| ID | Requirement | Checks |
|---|---|---|
| proxy.R1 | When a scope starts, blackice shall start that scope's proxy outside the scope, listening only on 127.0.0.1 at a randomly chosen port, before the command starts. | P0-01 |
| proxy.R2 | When an HTTP `CONNECT` request or a plain HTTP request names a host the policy does not allow, the proxy shall answer 403, write one `deny` receipt with the reason code, and not look the name up. | P0-02 |
| proxy.R3 | When the host is allowed, the proxy shall resolve the name itself, check every address it gets against the policy, and connect only to an address that passes. It shall never connect to an address supplied by the client for that name. | P0-03 |
| proxy.R4 | If every address of an allowed name is refused, for example because it is a private or loopback address, the proxy shall answer 403 and write a `deny` receipt with the address reason code. | P0-02 |
| proxy.R5 | When the request names an IP address instead of a host name, the proxy shall decide it with the policy's address rules only. | P0-03 |
| proxy.R6 | When the proxy allows a connection, it shall write one `allow` receipt with the matching rule, the host, the address it connected to and the port. | P0-03 |
| proxy.R7 | If a request is malformed, its header exceeds a fixed size, or it is neither `CONNECT` nor a plain HTTP request with an absolute URL, the proxy shall refuse it with a 4xx status and write a `deny` receipt. | P0-02 |
| proxy.R8 | When the scope ends, blackice shall stop the proxy and close every connection it is relaying. | P0-05 |

## Design

The proxy speaks the standard HTTP proxy protocol, which almost every command-line tool already supports
through the `HTTPS_PROXY` family of variables. For HTTPS it only opens a tunnel: it reads the host and port from
the `CONNECT` line, decides, and then copies bytes both ways without reading them. Because the proxy does its
own name lookups, a refused name is never resolved at all, and an allowed name cannot be pointed at a local
service by the program.

**Technical.**

- Listener: TCP on `127.0.0.1:<random port>`, one proxy per scope, inside the `blackice` process. The port is
  passed to the backend as an allowed loopback port.
- `CONNECT host:port`: decide on `host`; on allow, reply `200 Connection established` and splice bytes.
- Plain HTTP (`GET http://host/path`): decide on the URL host; forward the request to the checked address.
- Decision order: host or IP literal check, then resolution (allowed names only), then the address check on
  each result (see [policy](policy.md)).
- Responses on refusal: 403 for a policy refusal, 400 or 405 for a malformed or unsupported request.
- Every decision writes one receipt with `point: proxy` (see [receipts](receipts.md)).
- Limits:
  - The `CONNECT` host is what the client says. The proxy binds it to a real destination by resolving it
    itself, but it does not read the TLS handshake: SNI, ECH and certificates are not checked, and the tunnel
    carries whatever the client sends to the allowed address.
  - Ports are not a policy dimension in v0: an allowed host is allowed on any port.
  - Only HTTP and HTTPS through the proxy are covered. Other protocols, UDP and QUIC are meant to be blocked
    entirely by the backend, which allows only the proxy and relay ports; each platform spec says what is
    verified.
  - Data sent to an allowed destination is out of scope.
  - Untested in v0: another local process taking the proxy's port after a crash, and one scope trying to use
    another scope's proxy.

## Tasks

| Task | Owner | State | Blocked by |
|---|---|---|---|
| `CONNECT` and plain HTTP proxy on a random loopback port | codex-network | todo | |
| Resolve allowed names in the proxy and dial only checked addresses | codex-network | todo | |
| One receipt per decision | codex-network | todo | |
| Bound header size and refuse unsupported requests | codex-network | todo | |
| Tests: refused name, allowed name, private address behind an allowed name, IP literal | codex-network | todo | |

## Evidence

| Covers | Kind | Link | Note |
|---|---|---|---|
| proxy.R2 | probe | - | Feasibility only, no blackice code: on macOS 27.0.1 (SIP on and off) and Linux, a command confined to one loopback port reached a stand-in proxy, which received `CONNECT example.com:443` while direct DNS failed inside the sandbox |

## Terms

CONNECT proxy, proxy variables, policy, receipt, reason code, loopback, DNS, SNI, ECH, TLS, scope
