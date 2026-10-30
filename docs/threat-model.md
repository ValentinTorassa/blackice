# Threat model

blackice is an experimental local network-permission system. The first intended usable release covers both ordinary applications and managed command sessions on macOS and Linux. A command-only demonstration does not complete that release.

The current core implements policy parsing, destination decisions and receipt primitives. Its Linux backend is a refusal stub at the reviewed core baseline; macOS contains an experimental Seatbelt launcher. A successful build or a backend's static availability flag is not evidence that all of the guarantees below hold.

## Assets and actors

The assets are effective network permissions, workload-to-scope identity, temporary-grant lifetime, policy/control authority, provider credentials and useful decision records.

| Actor or component | Intended authority |
| --- | --- |
| Workload, agent and descendants | Use granted network access; request changes. They cannot approve their own expansion or disable mandatory policy. |
| Independent owner | Authorize bounded changes and recovery through a protected control path. |
| Core / control service | Validate requests, preserve scope identity and coordinate policy activation. |
| Native backend and privileged helper | Enforce the acknowledged boundary before execution, with only required privileges. |
| Proxy and model relay | Connect on behalf of one verified scope, within its destination and lifetime limits. |
| Observer or receipt consumer | Read authorized metadata. Observing an event does not grant policy authority. |

The OS and the trusted installation are part of the trusted computing base. A system administrator, compromised kernel, malicious firmware, and physical attacker with control of the machine are outside this model.

## What is being constrained

The managed command may be buggy or adversarial. It can try direct sockets, alternate address families and protocols, resolver APIs, subprocesses, detached children, inherited descriptors, local proxies, IPC to existing daemons, policy/control operations and malformed input.

Network filtering alone does not isolate files, protect all existing credentials, prevent same-user process tampering, inspect payloads for secrets or stop exfiltration to an authorized endpoint. A shared-UID workload is not automatically a securely isolated user. Filesystem and process-control exposure must not be hidden behind a general sandbox claim.

## Required boundaries

1. **Launch:** identify and enroll the exact process instance, attach the required policy generation, acknowledge success, then execute user code. A PID scan or moving a process after it starts is insufficient.
2. **Descendants and delegation:** qualify child inheritance and containment. Work delegated to an already-running service needs a separate boundary. Killing a parent does not prove that its children or proxy connections ended.
3. **Destination:** deny paths outside the supported policy. DNS, IPv4/IPv6, TCP/UDP, loopback, LAN and existing sockets require explicit coverage; one TCP test does not establish deny-all.
4. **Control:** authenticate the actor, operation and target scope independently of a claimed PID, executable name, environment variable or workspace file. Temporary permission must fit every applicable mandatory limit.
5. **Lifetime:** terminate temporary authority at the earliest applicable expiry/session boundary. Distinguish preventing new connections from terminating existing ones, including proxy-owned connections.
6. **Observation:** receipts explain decisions without influencing enforcement. Bounded logging, explicit gaps and owner-configurable retention are necessary; a logging failure cannot grant access.

## Linux installation and privileges

The intended Linux path uses a root-owned workload cgroup outside the user's delegated subtree, a narrowly scoped helper and kernel packet enforcement. A separate backend implementation must prove enrollment, attribution and protocol coverage before advertising support.

An operator reads and runs the setup script with sudo. The launcher does not invoke sudo on behalf of a workload. Setup and teardown must operate on owned paths, validate ownership and symlinks, and leave unrelated firewall/cgroup configuration intact. File capabilities are privileges: group membership and executable access do not replace validation of each helper operation.

Mount-namespace hiding of resolver or daemon paths is a targeted mitigation. It does not by itself cover already-open descriptors, alternate socket names, `/proc` access, external service requests or all same-user IPC. Landlock and any additional confinement must be probed for the required ABI and tested, not inferred from a kernel version. Failure to provide a mandatory boundary must refuse strict launch.

## Proxy and real-model relay

The provider key stays in the relay outside every workload scope. It must not appear in workload environment variables, arguments, state files, receipts or recorded demonstrations. Disable process dumps where supported, keep credentials out of errors, and consider inheritance and process-inspection paths separately. Excluding the raw key does not eliminate the authority to spend through the relay.

The relay needs a fixed upstream, a model allowlist, bounded body/response sizes, request and spending limits, and a verified scope/lifetime binding. Client input must not override upstream credentials, choose arbitrary upstream destinations, or redirect a credential-bearing request elsewhere. Authentication to the relay is distinct from authentication of its upstream provider.

A local listening port is not a scope identity. Prevent cross-scope reuse, stale-port takeover and unbound requests. The first whole-agent wrapper shares one network envelope with its tools: tools may use destinations or relay access granted to the agent. Per-tool isolation requires a separately verified launch integration.

## Owner-grant limitation in the initial design

The proposed first control path treats same-user processes outside managed scopes as the owner. This is a limited convenience model, not proof of independent authority against an adversarial shared-user process. Hiding a control socket pathname alone cannot establish that stronger property.

Before claiming resistance to self-grant, test direct IPC, alternate paths, existing descriptors, process injection, helper invocation and delegation to unconfined daemons. Document exactly which attempts were blocked and what trusted-owner assumptions remain. Do not widen the threat claim just because one CLI invocation from inside a scope failed.

## Failure and evidence

The backend must report whether protection is active, degraded or unknown. The behavior after extension loss, packet-rule removal, proxy failure, broker restart, sleep, reboot and storage failure is platform-specific. Preserve valid mandatory policy where supported and refuse new strict work when the required boundary is unknown. Recovery belongs to an independently authorized operator.

Each native claim needs a controlled receiving endpoint, allowed control traffic, denied probes, host/build details and recorded limits. Include DNS, inherited sockets, process escape, expiry and fault behavior as applicable. A generated receipt or a policy evaluator result alone is not a network test.

The [policy contract](policy.md) describes the import capability gate. The repository's `evidence/` directory records actual runs; source review and unit vectors must be described as such.
