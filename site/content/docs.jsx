import Link from 'next/link';
import { SITE } from './site';
import { MATRIX, CHECKPOINTS, INVARIANTS, STATE_LABEL } from './status';

// Docs content. Everything describes the proposed design unless a page says it is verified.

function Note({ children }) {
  return <div className="note">{children}</div>;
}

function Code({ title, label, children }) {
  return (
    <figure className="code">
      {title || label ? (
        <figcaption>
          <span>{title}</span>
          {label ? <span className="code-label">{label}</span> : null}
        </figcaption>
      ) : null}
      <pre>{children}</pre>
    </figure>
  );
}

function StatusDot({ state }) {
  return (
    <span className={`state state-${state}`}>
      <span className="state-dot" aria-hidden="true" />
      {STATE_LABEL[state]}
    </span>
  );
}

export function MatrixTable() {
  return (
    <div className="table-wrap" tabIndex={0} aria-label="Platform status, scrollable">
      <table>
        <thead>
          <tr>
            <th scope="col">Platform</th>
            <th scope="col">Apps on the machine</th>
            <th scope="col">Tasks an agent runs</th>
          </tr>
        </thead>
        <tbody>
          {MATRIX.map((row) => (
            <tr key={row.os}>
              <th scope="row">{row.os}</th>
              {['apps', 'tasks'].map((k) => (
                <td key={k}>
                  <StatusDot state={row[k].state} />
                  <p>{row[k].how}</p>
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

const POLICY_EXAMPLE = `{
  "default": "deny",
  "allow": {
    "domains": ["registry.npmjs.org", "api.github.com"],
    "networks": []
  }
}`;

const RECEIPT_EXAMPLE = `{"time":"2026-10-30T12:00:03Z","scope":"t_7f3a","generation":"pg_12",
 "destination":"registry.npmjs.org:443","verdict":"allow","reason":"POLICY_ALLOW","enforcer":"proxy"}
{"time":"2026-10-30T12:00:04Z","scope":"t_7f3a","generation":"pg_12",
 "destination":"paste.example","verdict":"deny","reason":"NAME_NOT_IN_POLICY","enforcer":"resolver"}`;

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
          checkpoints have recorded evidence. See <Link href="/docs/status/">Status</Link>.
        </Note>
        <p>
          A coding agent runs commands on your machine: tests, installs, scripts. Each of those commands can connect
          anywhere your user can. {SITE.name} puts a network policy around a task before it starts. Every process the
          task spawns inherits that policy, and a process inside the task cannot grant itself more access.
        </p>
        <p>
          The same policy model covers apps that are already running on the machine. A host ceiling sits over
          everything, and nested scopes can only narrow it.
        </p>
        <h2>Quick look</h2>
        <Code title="terminal" label="Illustrative · CLI not frozen">{`$ ${SITE.name} run --policy policy.json -- fx
$ ${SITE.name} grant t_7f3a api.example.com --for 10m   # from outside the task, as the owner
$ tail -f receipts.jsonl                               # one line per decision`}</Code>
        <h2>Next</h2>
        <ul className="link-list">
          <li><Link href="/docs/scopes/">Scopes</Link>: where a policy applies.</li>
          <li><Link href="/docs/policies/">Policies</Link>: what may connect.</li>
          <li><Link href="/docs/fx/">fx integration</Link>: wrapping an agent without changing it.</li>
          <li><Link href="/docs/limits/">Limits</Link>: what it does not do.</li>
        </ul>
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
          has its own evidence gate: a shared command does not mean equal coverage.
        </p>
        <MatrixTable />
        <h2>PoC-0 checkpoints</h2>
        <p>A checkpoint is recorded only when the repository&apos;s <code>evidence/</code> folder holds its test record.</p>
        <ol className="checklist">
          {CHECKPOINTS.map(([id, name]) => (
            <li key={id}>
              <span className="mono faint">{id}</span>
              <span>{name}</span>
              <span className={`state state-${recordedSet.has(id) ? 'verified' : 'unverified'}`}>
                <span className="state-dot" aria-hidden="true" />
                {recordedSet.has(id) ? 'Recorded' : 'Not run'}
              </span>
            </li>
          ))}
        </ol>
        <h2>Design invariants</h2>
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
        <h2>Task scope</h2>
        <p>
          A command and every process it starts. {SITE.name} creates the scope and arms its policy before the
          command executes, so the first connection the command makes is already inside it. Children inherit the
          scope through fork and exec.
        </p>
        <h2>App scope</h2>
        <p>
          An app that is already on the machine, identified from operating-system evidence rather than from its
          process name. App scopes do not need {SITE.name} to launch the app.
        </p>
        <h2>Host ceiling</h2>
        <p>One policy, administered by the owner, over the whole machine. Every other scope sits under it.</p>
        <h2>Nesting</h2>
        <p>
          Scopes nest, and a nested scope can only narrow. The effective permission is the intersection of every
          ceiling that applies, so a narrower scope can never erase a mandatory deny.
        </p>
        <Note>
          Work handed to a system daemon on a task&apos;s behalf (launchd, <code>open</code>,{' '}
          <code>systemd-run --user</code>, docker) does not run as a child of the task. It is outside the task scope.
        </Note>
      </>
    ),
  },
  {
    slug: 'policies',
    group: 'Concepts',
    title: 'Policies',
    description: 'Deny by default, with allow lists for names and networks. DNS is part of the boundary.',
    body: () => (
      <>
        <Code title="policy.json" label="Illustrative · schema not frozen">{POLICY_EXAMPLE}</Code>
        <h2>Names and DNS</h2>
        <p>
          Inside a task scope, names that the policy does not allow do not resolve. A domain rule states how it is
          enforced and what it cannot see. A TLS server name sent by a client is not proof of the destination, so it is
          never trusted on its own.
        </p>
        <h2>Generations</h2>
        <p>
          A policy change commits as one generation with its own ID. Receipts name the generation that decided them. If
          a change fails, the previous generation stays in force; there is never a partial policy.
        </p>
        <h2>Unsupported rules fail loudly</h2>
        <p>
          If a backend cannot enforce something a policy requires, activation fails. Nothing is silently downgraded.
        </p>
        <h2>Vercel Sandbox</h2>
        <p>
          Proposed: a versioned importer for a tested subset of the{' '}
          <a href="https://vercel.com/docs/sandbox/concepts/firewall">Vercel Sandbox network policy</a>. Fields
          outside that subset are rejected, not ignored.
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
        <Code title="terminal · outside the task" label="Illustrative">{`$ ${SITE.name} grant t_7f3a api.example.com --for 10m
granted until 12:10:03`}</Code>
        <Code title="terminal · inside the task" label="Illustrative">{`$ ${SITE.name} grant t_7f3a api.example.com --for 10m
refused: grants come from outside the scope`}</Code>
        <h2>Who can grant</h2>
        <p>
          Only an authorized owner, from outside the scope. Being outside is necessary but not enough: the request has
          to come from an authenticated peer acting on protected control state. A process inside a task cannot widen
          its own scope or anyone else&apos;s.
        </p>
        <h2>When access ends</h2>
        <p>
          At the earliest bound: the grant&apos;s timeout, the end of the task, or a revocation. Expiry is enforced
          locally. What a revocation covers, including connections that are already open, is stated per backend.
        </p>
      </>
    ),
  },
  {
    slug: 'receipts',
    group: 'Concepts',
    title: 'Receipts',
    description: 'One JSON line per decision, with a stable reason code.',
    body: () => (
      <>
        <Code title="receipts.jsonl" label="Example format · simulated">{RECEIPT_EXAMPLE}</Code>
        <p>
          Each receipt names the scope, the policy generation, the destination, the verdict, a stable reason code and
          the point that enforced it. Because they are plain lines of JSON, <code>tail</code>, <code>grep</code> and{' '}
          <code>jq</code> work on them directly.
        </p>
        <h2>Gaps</h2>
        <p>If receipts are dropped, the gap is counted and reported. A logging failure never widens access.</p>
        <h2>Privacy</h2>
        <p>Receipts stay on the machine. There is no account and no telemetry.</p>
      </>
    ),
  },
  {
    slug: 'cli',
    group: 'Reference',
    title: 'CLI',
    description: 'The commands under discussion. The contract is not frozen yet.',
    body: () => (
      <>
        <h2>
          <code>{SITE.name} run</code>
        </h2>
        <Code>{`${SITE.name} run --policy <file> -- <command> [args...]`}</Code>
        <p>Creates a task scope, arms the policy, then runs the command inside it.</p>
        <h2>
          <code>{SITE.name} grant</code>
        </h2>
        <Code>{`${SITE.name} grant <scope> <destination> --for <duration>`}</Code>
        <p>Gives a scope temporary access. Owner only, from outside the scope.</p>
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
        <MatrixTable />
        <h2>macOS</h2>
        <p>
          <strong>Tasks.</strong> An experimental session mode applies the built-in sandbox before the command executes,
          plus a local proxy for names, because the sandbox cannot filter by remote host.
        </p>
        <p>
          <strong>Apps.</strong> Control of apps that are already running needs a Network Extension signed with a
          Developer ID and approved by the user. Session mode never counts as app control.
        </p>
        <h2>Linux</h2>
        <p>
          <strong>Tasks.</strong> Each task gets a cgroup v2 before it executes. Enforcement uses nftables or eBPF
          cgroup hooks. The backend is chosen by tests: socket attribution, UDP, IPv6, launch ordering and coexistence
          with existing host rules.
        </p>
        <p>
          <strong>Apps.</strong> Host-wide attribution without PID races or trusting process names is the main open
          risk. The mechanism is chosen after a spike.
        </p>
      </>
    ),
  },
  {
    slug: 'fx',
    group: 'Reference',
    title: 'fx integration',
    description: 'Wrap fx without changing it.',
    body: () => (
      <>
        <Code title="terminal" label="Illustrative">{`$ ${SITE.name} run --policy policy.json -- fx`}</Code>
        <p>
          This puts <a href="https://github.com/vercel-labs/fx">fx</a> and everything it starts in one task scope,
          with no changes to fx.
        </p>
        <h2>Why it helps</h2>
        <p>
          In its default <code>auto</code> mode, fx runs recognized project commands such as tests, builds and local
          installs directly, and sends unfamiliar commands to a reviewer model (
          <a href="https://fx.sh/docs/configure-fx/permissions">fx permissions</a>). Since 0.0.5, approved commands run
          as ordinary host subprocesses (
          <a href="https://github.com/vercel-labs/fx/blob/main/CHANGELOG.md">changelog</a>). A network policy limits
          where any of those commands can connect, whatever approved them.
        </p>
        <h2>Model traffic</h2>
        <Note>
          <strong>Designed, not yet verified.</strong> fx reaches its model through a relay outside the task, so the
          model key never enters the scope.
        </Note>
        <p>What the relay does not do:</p>
        <ul>
          <li>
            A tool inside the scope can still send any content to the allowed model endpoint through the relay. The relay
            keeps the key out of the scope, nothing more.
          </li>
          <li>
            In this first version the key is protected from the scope, not from other processes of the same user that run
            outside every scope.
          </li>
        </ul>
        <h2>Limits of wrapping</h2>
        <ul>
          <li>A separate scope per tool call needs a launch hook in fx. That is future work.</li>
          <li>MCP servers are not covered by the first proof.</li>
        </ul>
      </>
    ),
  },
  {
    slug: 'limits',
    group: 'Project',
    title: 'Limits',
    description: 'What blackice does not do. These limits are declared, not hidden.',
    body: () => (
      <>
        <ul className="limits">
          <li><strong>Network only.</strong> Files, processes and credentials need their own controls.</li>
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
            <strong>Failure behavior.</strong> What happens when a broker, proxy or extension fails is stated per
            fault and backend. There is no blanket fail-closed claim.
          </li>
        </ul>
      </>
    ),
  },
];

export const GROUPS = ['Overview', 'Concepts', 'Reference', 'Project'];
