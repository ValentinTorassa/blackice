import Link from 'next/link';
import { SITE } from './site';
import { CHECKPOINTS, INVARIANTS } from './status';
import { highlight } from './highlight';
import CopyButton from '../components/CopyButton';
import StatusCards from '../components/StatusCards';
import { IconArrowRight, IconFlag, IconInfo, IconNested, IconPolicy, IconTerminal } from '../components/Icons';

// Docs content for the v0 design. Nothing is verified until evidence/ says so.
// Parts with code in the repository are in the present tense; parts not built yet are in the future tense.

function textOf(node) {
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map(textOf).join('');
  return node?.props ? textOf(node.props.children) : '';
}

const slugOf = (s) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');

// A section heading that links to itself. The table of contents is built from these.
function H2({ children }) {
  const id = slugOf(textOf(children));
  return (
    <h2 id={id}>
      <a className="h-anchor" href={`#${id}`}>
        {children}
        <span className="h-hash" aria-hidden="true">
          #
        </span>
      </a>
    </h2>
  );
}

function Note({ children }) {
  return (
    <div className="note">
      <IconInfo size={16} className="note-icon" />
      <div>{children}</div>
    </div>
  );
}

// For a terminal block, copy only the commands, without the prompt or comments.
function copyText(text) {
  if (typeof text !== 'string') return null;
  const cmds = text.split('\n').filter((l) => l.startsWith('$ '));
  if (!cmds.length) return text;
  return cmds.map((l) => l.slice(2).replace(/\s+#.*$/, '')).join('\n');
}

function Code({ title, label, children }) {
  const copy = copyText(children);
  const caption = title || label;
  return (
    <figure className={`code${caption ? '' : ' code-bare'}`}>
      {caption ? (
        <figcaption>
          <span className="code-title">{title}</span>
          <span className="code-meta">
            {label ? <span className="code-label">{label}</span> : null}
            {copy ? <CopyButton text={copy} /> : null}
          </span>
        </figcaption>
      ) : copy ? (
        <CopyButton text={copy} floating />
      ) : null}
      <pre>{highlight(children)}</pre>
    </figure>
  );
}

const SCOPE = 's-7f3a91c2';

const POLICY_EXAMPLE = `{
  "version": "blackice.policy/v0",
  "network": {
    "mode": "allowlist",
    "allow": ["registry.npmjs.org", "*.github.com"],
    "subnets": { "allow": [], "deny": ["203.0.113.0/24"] },
    "ports": [443]
  }
}`;

const RECEIPT_EXAMPLE = `{"ts":"2026-10-30T12:00:03.120Z","scope":"${SCOPE}","policy":"cae35a3beb20","gen":1,"point":"proxy","event":"connect","verdict":"allow","reason":"allowed_by_rule","rule":"registry.npmjs.org","host":"registry.npmjs.org","ip":"198.51.100.24","port":443}
{"ts":"2026-10-30T12:00:04.871Z","scope":"${SCOPE}","policy":"cae35a3beb20","gen":1,"point":"proxy","event":"connect","verdict":"deny","reason":"no_matching_rule","host":"paste.example","port":443}`;

const RECEIPT_FIELDS = [
  ['ts', 'Time of the decision, in UTC.'],
  ['scope', 'The scope ID.'],
  ['policy, gen', 'A short hash of the policy and its generation.'],
  ['point', 'Where it was enforced: proxy, kernel, relay, control or app_filter.'],
  ['event', 'connect, http, scope_start, scope_end, grant, revoke, relay_call, kernel_drop or warning.'],
  ['verdict, reason', 'allow or deny, and a stable reason code.'],
  ['rule', 'The policy entry that decided, as written in the file.'],
  ['host, ip, port, detail', 'The destination, and anything else worth keeping.'],
];

// policy.Reason: the codes the policy decides with.
const POLICY_ALLOW = ['allowed_by_rule', 'allowed_by_mode', 'allowed_subnet', 'allowed_port', 'public_address'];
const POLICY_DENY = [
  'no_matching_rule',
  'mode_deny_all',
  'ip_literal_needs_subnet',
  'denied_subnet',
  'local_or_private_address',
  'transition_address',
  'port_not_allowed',
  'invalid_host',
];

// The proxy's own codes, for grants and for connections it cannot complete.
const PROXY_CODES = [
  ['granted', 'Allowed by an active grant. rule names the grant.'],
  ['bad_request', 'The request could not be parsed (400).'],
  ['resolve_failed', 'An allowed name did not resolve (502).'],
  ['upstream_unreachable', 'No checked address accepted the connection (502).'],
  ['sni_mismatch', 'The TLS server name differs from the CONNECT host. The tunnel is closed.'],
  ['sni_missing', 'A TLS handshake for a name carried no server name. The tunnel is closed.'],
  ['tls_unparsed', 'The TLS handshake could not be parsed. The tunnel is closed.'],
  ['not_tls', 'The first bytes through CONNECT were not TLS. The tunnel is closed.'],
  ['grant_expired', 'A connection opened under a grant was closed when the grant expired.'],
  ['grant_revoked', 'A connection opened under a grant was closed when the owner revoked it.'],
  ['grant_watchdog_failed', 'The task that ends a grant could not start (503).'],
];

const NEXT = [
  ['/docs/scopes/', 'Scopes', 'Where a policy applies.', IconNested],
  ['/docs/policies/', 'Policies', 'What may connect, and how names and addresses are checked.', IconPolicy],
  ['/docs/fx/', 'fx integration', 'A scope for every command fx runs, or one around the whole agent.', IconTerminal],
  ['/docs/limits/', 'Limits', 'What it does not do, declared up front.', IconFlag],
];

function Codes({ label, codes, tone }) {
  return (
    <div className="codes-group">
      <p className="codes-label">{label}</p>
      <p className="chip-list">
        {codes.map((c) => (
          <code key={c} className={`chip chip-${tone}`}>
            {c}
          </code>
        ))}
      </p>
    </div>
  );
}

export const DOCS = [
  {
    slug: '',
    group: 'Overview',
    title: 'Introduction',
    description: `${SITE.name} gives apps and agent tasks network permissions on macOS and Linux. It is native, headless and driven by a policy file.`,
    body: ({ recorded }) => (
      <>
        <Note>
          <strong>Proof of concept.</strong> Nothing in these docs is verified yet. {recorded} of {CHECKPOINTS.length}{' '}
          checkpoints have recorded evidence; see <Link href="/docs/status/">Status</Link>. Parts that are not built yet
          are written in the future tense.
        </Note>
        <p>
          A coding agent runs commands on your machine: tests, installs, scripts. Each of those commands can connect
          anywhere your user can. {SITE.name} will put a network policy around a task before it starts. Every process
          the task spawns will inherit that policy, and no process inside the task will be able to grant itself more
          access.
        </p>
        <p>
          The same policy format will cover apps that are already running on the machine. A host ceiling will sit over
          everything, and nested scopes will only be able to narrow it.
        </p>
        <H2>Quick look</H2>
        <Code title="terminal" label="Illustrative · CLI not frozen">{`$ ${SITE.name} run --policy policy.json -- fx
# from outside the scope, as the owner:
$ ${SITE.name} grant ${SCOPE} api.example.com --for 10m
$ tail -f ~/.local/state/${SITE.name}/scopes/${SCOPE}/receipts.jsonl`}</Code>
        <H2>Next</H2>
        <div className="next-cards">
          {NEXT.map(([href, title, text, Icon]) => (
            <Link key={href} href={href} className="next-card">
              <span className="next-icon">
                <Icon size={16} />
              </span>
              <span className="next-title">
                {title}
                <IconArrowRight size={14} />
              </span>
              <span className="next-text">{text}</span>
            </Link>
          ))}
        </div>
      </>
    ),
  },
  {
    slug: 'status',
    group: 'Overview',
    title: 'Status',
    description: 'What exists, what is being tested, and how a claim earns the word "verified".',
    body: ({ recordedSet }) => (
      <>
        <p>
          The first usable release needs app control and task control on both macOS and Linux. Each of the four cells
          has its own evidence gate: a shared command does not mean equal coverage. States are computed when this site
          is built. <strong>Verified</strong> needs a recorded run in <code>evidence/</code>; <strong>Built</strong>{' '}
          means the code is in the repository.
        </p>
        <StatusCards />
        <H2>PoC-0 checkpoints</H2>
        <p>
          A checkpoint is recorded only when the repository&apos;s <code>evidence/</code> folder holds its test record.
        </p>
        <ol className="checklist">
          {CHECKPOINTS.map(([id, name]) => (
            <li key={id}>
              <span className="mono faint">{id}</span>
              <span>{name}</span>
              <span className={`state state-${recordedSet.has(id) ? 'verified' : 'pending'}`}>
                <span className="state-dot" aria-hidden="true" />
                {recordedSet.has(id) ? 'Recorded' : 'Not run'}
              </span>
            </li>
          ))}
        </ol>
        <H2>Release gap</H2>
        <p>Before a first usable release, beyond this proof of concept:</p>
        <ul>
          <li>App control on macOS: the Network Extension filter, signed with a Developer ID.</li>
          <li>App control on Linux: a mechanism chosen after a spike.</li>
          <li>Owner authentication for grants, beyond &quot;same user, outside every scope&quot;.</li>
          <li>Protocols other than HTTP and TLS through the proxy.</li>
          <li>Listening inside a scope, for dev servers and tests that open a port.</li>
          <li>Recorded evidence for every cell above.</li>
        </ul>
        <H2>Design invariants</H2>
        <p>Every backend has to keep these.</p>
        <ol className="invariants">
          {INVARIANTS.map((text, i) => (
            <li key={text}>
              <span className="mono faint">I-{String(i + 1).padStart(2, '0')}</span>
              <span>{text}</span>
            </li>
          ))}
        </ol>
      </>
    ),
  },
  {
    slug: 'scopes',
    group: 'Concepts',
    title: 'Scopes',
    description: 'A scope is where a policy applies: a task, an app, or the whole host.',
    body: () => (
      <>
        <H2>Task scope</H2>
        <p>
          A command and every process it starts. {SITE.name} will create the scope and arm its policy before the
          command executes, so the first connection the command makes is already inside it. Children inherit the scope
          through fork and exec.
        </p>
        <p>
          Each scope has an ID, such as <code>{SCOPE}</code>, and a state directory under{' '}
          <code>~/.local/state/{SITE.name}/scopes/</code>. Only the {SITE.name} process writes there; inside the scope
          it will be read-only.
        </p>
        <H2>App scope</H2>
        <p>
          An app that is already on the machine. On macOS, a Network Extension filter will identify apps by their
          code-signing identity, not their process name, and apply the same policy format and receipts. App scopes will
          not need {SITE.name} to launch the app. On Linux, the mechanism will be chosen after a spike.
        </p>
        <H2>Host ceiling</H2>
        <p>One policy, administered by the owner, over the whole machine. Every other scope will sit under it.</p>
        <H2>Nesting</H2>
        <p>
          Scopes will nest, and a nested scope will only be able to narrow. The effective permission is the
          intersection of every ceiling that applies, so a narrower scope can never erase a mandatory deny.
        </p>
        <Note>
          Work handed to a system daemon on a task&apos;s behalf (launchd, <code>open</code>,{' '}
          <code className="nb">systemd-run --user</code>, docker) does not run as a child of the task. It is outside the task scope.
        </Note>
      </>
    ),
  },
  {
    slug: 'policies',
    group: 'Concepts',
    title: 'Policies',
    description: 'A strict JSON file: a mode, allowed names, subnets and ports.',
    body: () => (
      <>
        <Code title="policy.json" label="Policy v0 · example">
          {POLICY_EXAMPLE}
        </Code>
        <H2>Modes</H2>
        <p>
          <code className="nb">deny-all</code> refuses every destination. <code className="nb">allow-all</code> allows
          public addresses. <code className="nb">allowlist</code> allows only the names and subnets the file lists.
        </p>
        <H2>Names</H2>
        <p>
          <code>allow</code> takes exact names and names with one leading wildcard. <code>example.com</code> matches
          only example.com; <code>*.example.com</code> matches any name below it, but not example.com itself. Names are
          compared in lowercase, without a trailing dot. Forms such as <code>a.*.com</code> or a bare <code>*</code>{' '}
          are refused.
        </p>
        <H2>Addresses and DNS</H2>
        <p>
          A command inside a scope will not reach the network directly. It will reach only a local proxy outside the
          scope, which matches the host name against the policy and resolves allowed names itself.
        </p>
        <p>
          Every resolved address is checked again. Denied subnets always lose and allowed subnets win. Loopback,
          private, link-local, CGNAT and multicast addresses are refused unless an allowed subnet covers them, so an
          allowed name that resolves to 127.0.0.1 cannot reach local services. A destination written as an IP address
          is allowed only by an allowed subnet.
        </p>
        <H2>Ports</H2>
        <p>
          <code>ports</code> lists the destination ports a scope may reach. Without it, 80 and 443 are allowed. The port
          is checked first, before any name or DNS work, and a grant never lifts a port refusal.
        </p>
        <H2>A strict file</H2>
        <p>
          Unknown fields are rejected, so a typo cannot widen a policy. If a backend cannot enforce something a policy
          requires, activation will fail. Nothing is silently downgraded.
        </p>
        <H2>Generations</H2>
        <p>
          The policy will be loaded once, when the scope starts, and never read again from disk. Receipts name it by a
          short hash and a generation number. A change, such as a grant, will commit as a new generation, all at once;
          if it fails, the previous generation stays in force.
        </p>
        <H2>Vercel Sandbox</H2>
        <p>
          An importer will read a tested subset of the{' '}
          <a href="https://vercel.com/docs/sandbox/concepts/firewall">Vercel Sandbox network policy</a> and refuse what
          v0 cannot express, such as <code>www.*.com</code> or a bare <code>*</code>. Fields outside that subset will be
          rejected, not ignored.
        </p>
      </>
    ),
  },
  {
    slug: 'grants',
    group: 'Concepts',
    title: 'Grants',
    description: 'Temporary access, given by the owner from outside the scope, that ends on its own.',
    body: () => (
      <>
        <Code title="terminal · outside the scope" label="Illustrative · output not frozen">{`$ ${SITE.name} grant ${SCOPE} api.example.com --for 10m
granted until 12:10:03`}</Code>
        <Code title="terminal · inside the scope" label="Illustrative · output not frozen">{`$ ${SITE.name} grant ${SCOPE} api.example.com --for 10m
error: the control socket is not reachable from inside a scope`}</Code>
        <H2>Who can grant</H2>
        <p>
          Grants will travel over a control socket that the scope cannot reach: a sandbox rule on macOS, a mount
          namespace on Linux. A process inside a task will not be able to widen its own scope or anyone else&apos;s.
        </p>
        <p>
          In v0, any process of the same user outside every scope counts as the owner. That is a declared limit;
          stronger owner checks, such as Touch ID or polkit, are an open question.
        </p>
        <H2>When access ends</H2>
        <p>
          At the earliest bound: the grant&apos;s timeout, the end of the task, or a revocation. Expiry will be enforced
          locally. What a revocation covers, including connections that are already open, will be stated per backend.
        </p>
      </>
    ),
  },
  {
    slug: 'receipts',
    group: 'Concepts',
    title: 'Receipts',
    description: 'One flat JSON line per decision, with a stable reason code.',
    body: () => (
      <>
        <Code title="receipts.jsonl" label="Format v0 · simulated values">
          {RECEIPT_EXAMPLE}
        </Code>
        <p>
          Each receipt is one line of flat JSON. Fields without a value are left out, so <code>tail</code>,{' '}
          <code>grep</code> and <code>jq</code> work on them directly.
        </p>
        <div className="table-wrap" tabIndex={0} aria-label="Receipt fields, scrollable">
          <table>
            <thead>
              <tr>
                <th scope="col">Field</th>
                <th scope="col">Meaning</th>
              </tr>
            </thead>
            <tbody>
              {RECEIPT_FIELDS.map(([field, meaning]) => (
                <tr key={field}>
                  <th scope="row">
                    <code>{field}</code>
                  </th>
                  <td>{meaning}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <H2>Reason codes</H2>
        <p>
          Reason codes are part of the receipt contract: once v0 is frozen, they change only with a contract change.
          The policy decides with these.
        </p>
        <div className="codes">
          <Codes label="Allow" codes={POLICY_ALLOW} tone="allow" />
          <Codes label="Deny" codes={POLICY_DENY} tone="deny" />
        </div>
        <p>The proxy adds its own, for grants and for connections it cannot complete.</p>
        <div className="table-wrap" tabIndex={0} aria-label="Proxy reason codes, scrollable">
          <table>
            <thead>
              <tr>
                <th scope="col">Code</th>
                <th scope="col">Meaning</th>
              </tr>
            </thead>
            <tbody>
              {PROXY_CODES.map(([code, meaning]) => (
                <tr key={code}>
                  <th scope="row">
                    <code className={code === 'granted' ? 'chip chip-allow' : 'chip chip-neutral'}>{code}</code>
                  </th>
                  <td>{meaning}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p>The relay and the control socket list their own codes in the source.</p>
        <H2>Where they live</H2>
        <p>
          In <code>~/.local/state/{SITE.name}/scopes/&lt;id&gt;/receipts.jsonl</code>. Each scope has a single writer,
          the {SITE.name} process. Backends report to it, so lines never interleave.
        </p>
        <H2>Gaps</H2>
        <p>
          Lines that could not be written are counted and reported when the scope ends, so a gap in the log is visible.
          On Linux, lost kernel events will be counted the same way. A logging failure never widens access.
        </p>
        <H2>Privacy</H2>
        <p>Receipts stay on the machine. There is no account and no telemetry.</p>
      </>
    ),
  },
  {
    slug: 'cli',
    group: 'Reference',
    title: 'CLI',
    description: 'The commands planned for v0. The contract is not frozen yet.',
    body: () => (
      <>
        <H2>
          <code>{SITE.name} run</code>
        </H2>
        <Code>{`${SITE.name} run --policy <file> [--name <name>] -- <command> [args...]`}</Code>
        <p>
          Will create a task scope, start its proxy outside the scope (and the model relay when asked), launch the
          command confined, and write receipts to the scope&apos;s state directory. The command gets{' '}
          <code>HTTP_PROXY</code>, <code>HTTPS_PROXY</code> and <code>ALL_PROXY</code> pointing at the proxy.
        </p>
        <H2>
          <code>{SITE.name} grant</code>
        </H2>
        <Code>{`${SITE.name} grant <scope> <host> --for <duration>`}</Code>
        <p>Will give a scope temporary access to one host. Owner only, over a control socket the scope cannot reach.</p>
        <Note>
          Status, revocation and app-scope commands will be documented when the contract is frozen. Until then, flags
          and output may change.
        </Note>
      </>
    ),
  },
  {
    slug: 'platforms',
    group: 'Reference',
    title: 'Platforms',
    description: 'How each operating system enforces a scope, and what is tested.',
    body: () => (
      <>
        <StatusCards />
        <H2>macOS</H2>
        <p>
          <strong>Tasks.</strong> An experimental session mode. The command will run under the built-in sandbox
          (Seatbelt, started through <code>sandbox-exec</code>, which Apple marks as deprecated). The profile denies
          outbound connections except to the scope&apos;s local proxy and relay, and denies writes to the scope&apos;s
          state directory. The sandbox cannot filter by host name, so names go through the proxy.
        </p>
        <p>
          <strong>Apps.</strong> A Network Extension filter, written in Swift, will decide per app, by code-signing
          identity, and per destination, with the same policy format and receipts. It needs Apple&apos;s networking
          entitlement and a Developer ID signature to run, so until then its state can be at most{' '}
          <em>Built, unsigned</em>. Session mode never counts as app control.
        </p>
        <H2>Linux</H2>
        <p>
          <strong>Tasks.</strong> Each task will get a root-owned cgroup v2 before it executes. eBPF programs on that
          cgroup will admit only TCP connections to the scope&apos;s local proxy. Refusals go to a per-scope ring buffer
          and become receipts; ring-buffer loss is counted and never allows traffic.
        </p>
        <p>
          A small helper with file capabilities, never {SITE.name} itself, will start the command paused, enroll it,
          arm the programs and only then let it run. A private mount namespace will hide resolver and daemon sockets
          and make the state directory read-only. Landlock and seccomp will close abstract Unix sockets, raw sockets
          and io_uring. Host nftables rules are not changed. The owner installs the helper with a short setup script,
          run with sudo.
        </p>
        <p>
          <strong>Apps.</strong> Host-wide attribution without PID races or trust in process names is the main open
          risk. The mechanism will be chosen after a spike.
        </p>
      </>
    ),
  },
  {
    slug: 'fx',
    group: 'Reference',
    title: 'fx integration',
    description: 'A scope for every command fx runs, or one scope around the whole agent.',
    body: () => (
      <>
        <Note>
          <strong>Designed, not yet verified.</strong> The per-command mode needs a small patch to fx that is not part
          of fx upstream.
        </Note>
        <H2>A scope per command</H2>
        <Code title="fx with a small blackice hook patch (not upstream)" label="Illustrative">{`# fx's shell tool asks to run:
npm test
# the hook runs it as:
${SITE.name} run --policy policy.json -- npm test`}</Code>
        <p>
          A small, declared patch adds a built-in PreToolUse handler to{' '}
          <a href="https://github.com/vercel-labs/fx">fx</a>. For the shell tool, it will rewrite each call to run
          through <code>{SITE.name} run</code>, so every command fx launches gets its own scope and its own receipts.
          fx itself, and its model traffic, stay outside the scopes. Each scope will also get a scrubbed environment,
          so secrets in fx&apos;s environment do not pass in.
        </p>
        <p>
          The patch will live in this repository under <code>integrations/fx/</code>. fx is Apache-2.0.
        </p>
        <H2>One scope around fx</H2>
        <Code title="terminal" label="Illustrative">{`$ ${SITE.name} run --policy policy.json -- fx`}</Code>
        <p>
          The fallback: fx and everything it starts in one task scope, with no changes to fx. In this mode, fx will
          reach its model through a relay outside the scope, so the model key never enters it.
        </p>
        <p>What the relay will not do:</p>
        <ul>
          <li>
            A tool inside the scope can still send any content to the allowed model endpoint through the relay. The
            relay keeps the key out of the scope, nothing more.
          </li>
          <li>
            In this first version the key is protected from the scope, not from other processes of the same user that
            run outside every scope.
          </li>
        </ul>
        <H2>Why it helps</H2>
        <p>
          In its default <code>auto</code> mode, fx runs recognized project commands such as tests, builds and local
          installs directly, and sends unfamiliar commands to a reviewer model (
          <a href="https://fx.sh/docs/configure-fx/permissions">fx permissions</a>). Since 0.0.5, approved commands run
          as ordinary host subprocesses (
          <a href="https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md">changelog</a>). A network policy limits
          where any of those commands can connect, whatever approved them.
        </p>
        <H2>Limits</H2>
        <ul>
          <li>MCP servers are not covered by the first proof.</li>
          <li>In the per-command mode, fx&apos;s own connections, model traffic included, are outside every scope.</li>
        </ul>
      </>
    ),
  },
  {
    slug: 'limits',
    group: 'Project',
    title: 'Limits',
    description: `What ${SITE.name} does not do. These limits are declared, not hidden.`,
    body: () => (
      <>
        <ul className="limits">
          <li>
            <strong>Network only.</strong> Files, processes and credentials need their own controls.
          </li>
          <li>
            <strong>HTTP and TLS only, in v0.</strong> Allowed destinations are reached through the local proxy, so
            only HTTP and TLS over CONNECT can be allowed. Other protocols are refused.
          </li>
          <li>
            <strong>Clients only, in v0.</strong> Nothing inside a task scope can listen for connections, not even on
            loopback, on macOS or Linux. Dev servers and tests that open a port cannot run inside a scope, and a scoped
            command reaches no loopback port except its own proxy and relay.
          </li>
          <li>
            <strong>Same-user owner, in v0.</strong> Processes of the same user outside every scope count as the
            owner, and can reach the model relay&apos;s port.
          </li>
          <li>
            <strong>Not a prompt-injection detector.</strong> It blocks connections the policy does not allow. Data
            sent to an allowed destination is out of scope.
          </li>
          <li>
            <strong>Outside daemons.</strong> Work handed to launchd, docker, a tmux server or another daemon runs
            outside the task.
          </li>
          <li>
            <strong>Inherited sockets.</strong> Sockets and file descriptors opened before the task, or passed in from
            outside, are not covered by its policy.
          </li>
          <li>
            <strong>Same-user isolation.</strong> A network policy does not isolate a hostile process from files or
            other IPC owned by the same user.
          </li>
          <li>
            <strong>macOS session mode.</strong> It relies on <code>sandbox-exec</code>, which Apple marks as
            deprecated, so it stays experimental. App control on macOS needs a signed Network Extension.
          </li>
          <li>
            <strong>Failure behavior.</strong> What happens when a broker, proxy or extension fails is stated per fault
            and backend. There is no blanket fail-closed claim.
          </li>
        </ul>
      </>
    ),
  },
];

export const GROUPS = ['Overview', 'Concepts', 'Reference', 'Project'];
