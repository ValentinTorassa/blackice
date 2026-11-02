import Link from 'next/link';
import { SITE, STATUS } from './site';
import { highlight } from './highlight';
import CopyButton from '../components/CopyButton';
import { FigArchitecture, FigAsk } from '../components/HowItWorks';
import { IconInfo } from '../components/Icons';

// Docs content. netshield is in planning: every page describes the design, and says so.

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

function Planned() {
  return (
    <Note>
      <strong>Planned.</strong> {STATUS} Nothing on this page is implemented yet; see the{' '}
      <Link href="/docs/roadmap/">Roadmap</Link>.
    </Note>
  );
}

function Code({ title, label, children, plain = false }) {
  return (
    <figure className="code">
      <figcaption>
        <span className="code-title">{title}</span>
        <span className="code-meta">
          {label ? <span className="code-label">{label}</span> : null}
          <CopyButton text={children} />
        </span>
      </figcaption>
      <pre>{plain ? children : highlight(children)}</pre>
    </figure>
  );
}

export const CONFIG_EXAMPLE = `# netshield.toml
mode = "ask"            # "accept-all", "ask" or "block-all"
timeout_seconds = 10    # no answer in time means deny

# Permanent rules. Checked before anything is asked.
[[allow]]
app = "com.example.agent"      # signing identifier
team = "ABCDE12345"            # Team ID
hosts = ["api.example.com"]

[[hook]]
on = "connection"
run = 'fx ask "Use the netshield skill to decide whether to approve the pending connection"'`;

const EVENT_EXAMPLE = `{
  "event": "connection",
  "id": "ev-7f3a91c2",
  "token": "<one-time token>",
  "app": { "signing_id": "com.example.tool", "team_id": "ABCDE12345", "path": "/Applications/Tool.app" },
  "host": "example.com",
  "ip": "203.0.113.7",
  "port": 443,
  "deadline": "2026-11-02T14:36:11Z"
}`;

const CLI = [
  ['netshield start / stop', 'Start or stop the daemon and the extension.'],
  ['netshield status', 'Mode, rules, approvals and paused connections.'],
  ['netshield mode accept-all | ask | block-all', 'Change the mode.'],
  ['netshield pending', 'Connections waiting for an answer.'],
  ['netshield approve --app ID --host HOST [--for 1h]', 'Allow one app to reach one host until the approval expires.'],
  ['netshield deny --app ID --host HOST', 'Drop the waiting connection and the ones like it.'],
];

const DECISIONS = [
  ['Ask mode', 'Asks only about connections that no rule or current approval covers.'],
  ['No answer in time', 'Deny after N seconds. The default is set after measuring how long macOS keeps a paused flow.'],
  ['Approval scope', 'One app, by signing identity, and one host, with an expiry.'],
  ['Approval storage', 'In memory, inside the extension. Permanent rules live in netshield.toml.'],
  ['Who can approve', "The hook, with the event's one-time token, or a person with Touch ID."],
  ['Configuration', 'A small strict parser for the TOML subset the file uses. No third-party dependency.'],
  ['Language', 'Swift for the extension, the CLI and the daemon.'],
];

const PHASES = [
  ['0', 'Developer ID signing', 'In progress', 'A binary signed with our Team ID is blocked by the extension and the rest of the Mac keeps working.'],
  ['1', 'Skeleton', 'Planned', 'mode block-all stops a curl, mode accept-all lets it through, and both leave a log line.'],
  ['2', 'Ask mode', 'Planned', 'A curl waits, approve releases it, and with no answer the timeout drops it.'],
  ['3', 'Hooks', 'Planned', 'A sample hook approves one host and denies another.'],
  ['4', 'The agent decides', 'Planned', 'fx decides ten test connections with nobody touching the keyboard.'],
  ['5', 'Hardening and evidence', 'Planned', 'Fault tests, evidence entries, notarization and an installer.'],
];

function Table({ label, head, rows }) {
  return (
    <div className="table-wrap" tabIndex={0} aria-label={label}>
      <table>
        <thead>
          <tr>
            {head.map((h) => (
              <th key={h} scope="col">
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map(([first, ...rest]) => (
            <tr key={first}>
              <th scope="row">{first}</th>
              {rest.map((c, i) => (
                <td key={i}>{c}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export const DOCS = [
  {
    slug: '',
    group: 'Overview',
    title: 'Introduction',
    description: `${SITE.name} is a headless network extension and CLI for macOS, where an agent can approve each new connection.`,
    body: () => (
      <>
        <Planned />
        <p>
          {SITE.name} is a network extension, a small daemon and a CLI. The extension sees every new outbound
          connection on the Mac, from any app. There are three modes. Accept all lets everything through, block all drops
          everything that no rule allows, and ask pauses each new connection that no rule covers while a hook asks an
          agent what to do.
        </p>
        <p>
          The agent answers on the command line, for example{' '}
          <code>netshield approve --app com.example.tool --host example.com --for 1h</code>. Nobody has to click a
          dialog.
        </p>
        <H2>Why</H2>
        <p>
          Agents run on developer machines all day and need to make network decisions without a person at the
          keyboard. The code that sees every connection on a machine is also a sensitive place for a dependency, so the
          aim is to keep {SITE.name} small and without third-party dependencies.
        </p>
        <H2>Relation to blackice</H2>
        <p>
          <a href="https://github.com/ValentinTorassa/blackice">blackice</a> confines one command and everything it
          starts, with a fixed policy file, and never asks. {SITE.name} covers the whole machine and asks an agent about
          each new connection. It starts from blackice&apos;s macOS app filter: the Network Extension, app identity from
          code signatures, and the TLS server name reader.
        </p>
      </>
    ),
  },
  {
    slug: 'how-it-works',
    group: 'Overview',
    title: 'How it works',
    description: 'The planned parts of netshield, and what happens to one connection in ask mode.',
    body: () => (
      <>
        <Planned />
        <H2>The parts</H2>
        <FigArchitecture n={1} />
        <ul>
          <li>
            <strong>Netshield.app</strong> has no UI and lives in <code>/Applications</code>, because macOS activates
            system extensions only from there. It contains the network extension and the <code>netshield</code> binary.
          </li>
          <li>
            <strong>The extension</strong> is an <code>NEFilterDataProvider</code>. It allows or drops each new flow, and
            in ask mode it pauses the flow until an answer arrives.
          </li>
          <li>
            <strong>The daemon</strong> runs as a LaunchAgent for the user, receives events over XPC and runs the hooks.
          </li>
        </ul>
        <H2>One connection in ask mode</H2>
        <FigAsk n={2} />
        <p>
          Rules from <code>netshield.toml</code> and current approvals are checked first, so the agent only hears about
          new destinations. A repeated connection, with the same app, host and port, raises one event.
        </p>
        <H2>Open problems</H2>
        <ul>
          <li>
            The deciding agent needs the network to reach its model. A fixed rule for it, bound to its signature, keeps
            it from waiting on its own approval.
          </li>
          <li>
            Host names and app names come from whoever opens the connection and end up in the model&apos;s prompt.
            Events carry them as structured fields, and the only answers are approve and deny.
          </li>
          <li>How long macOS keeps a paused flow is not measured yet. It sets the upper bound for the timeout.</li>
        </ul>
      </>
    ),
  },
  {
    slug: 'configuration',
    group: 'Reference',
    title: 'Configuration',
    description: 'netshield.toml and the event a hook receives. A proposal, not a stable format.',
    body: () => (
      <>
        <Planned />
        <H2>netshield.toml</H2>
        <Code title="netshield.toml" label="Proposal" plain>
          {CONFIG_EXAMPLE}
        </Code>
        <p>
          The parser is strict: an unknown key or a value of the wrong type stops {SITE.name} from starting instead of
          being guessed at.
        </p>
        <H2>The event a hook receives</H2>
        <p>
          The hook gets the event as JSON on stdin. The daemon also writes it to a file named in{' '}
          <code>NETSHIELD_EVENT_FILE</code>, because <code>fx ask</code> does not read stdin when the prompt is on the
          command line. The token is good for one answer to that event.
        </p>
        <Code title="stdin" label="Proposal">
          {EVENT_EXAMPLE}
        </Code>
      </>
    ),
  },
  {
    slug: 'cli',
    group: 'Reference',
    title: 'CLI',
    description: 'The planned commands.',
    body: () => (
      <>
        <Planned />
        <Table label="Commands, scrollable" head={['Command', 'What it does']} rows={CLI.map(([c, w]) => [<code key={c}>{c}</code>, w])} />
        <p>
          <code>approve</code> and <code>deny</code> need the event&apos;s token when a hook calls them. A person can run
          them by hand after confirming with Touch ID.
        </p>
      </>
    ),
  },
  {
    slug: 'roadmap',
    group: 'Project',
    title: 'Roadmap',
    description: 'The phases, each with the check that ends it, and the decisions taken so far.',
    body: () => (
      <>
        <Note>
          A phase is done when its check passes on a real Mac, not when the code compiles. The same plan is in{' '}
          <a href={`${SITE.repo}/blob/main/docs/plan.md`}>docs/plan.md</a>.
        </Note>
        <H2>Phases</H2>
        <Table label="Phases, scrollable" head={['Phase', 'Name', 'State', 'Done when']} rows={PHASES} />
        <H2>Decisions</H2>
        <Table label="Decisions, scrollable" head={['Topic', 'Decision']} rows={DECISIONS} />
      </>
    ),
  },
];

export const GROUPS = ['Overview', 'Reference', 'Project'];
