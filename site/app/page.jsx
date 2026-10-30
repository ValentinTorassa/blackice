import Link from 'next/link';
import { Nav, Footer } from '../components/Chrome';
import Scene from '../components/Scene';
import CopyCommand from '../components/CopyCommand';
import { SITE } from '../content/site';
import { MATRIX, CHECKPOINTS, STATE_LABEL } from '../content/status';
import { recordedCheckpoints } from '../lib/evidence';

const NOUNS = [
  ['Scope', 'Where a policy applies: a task and every process it starts, an app on the machine, or the host.'],
  ['Policy', 'Deny by default, with allow lists for names and networks. DNS is part of the boundary.'],
  ['Receipt', 'One JSON line per decision, with the scope, the policy generation and a stable reason code.'],
];

const PRINCIPLES = [
  ['Born inside', 'The policy attaches before exec, like chroot. The first connection already runs inside it.'],
  ['Only narrows', 'Anything can tighten a scope. Widening comes from the owner, outside the task, for a set time.'],
  ['Wraps any command', 'Goes in front of a command, like nice or timeout. fx needs no changes.'],
  ['Plain text out', 'Receipts are JSON lines, so tail, grep and jq just work.'],
];

const SESSION = [
  ['cmd', `${SITE.name} run --policy policy.json -- fx`],
  ['out', 'task t_7f3a  ·  policy pg_12  ·  armed'],
  ['cmd', 'curl -sI https://registry.npmjs.org', 'inside the task'],
  ['ok', 'HTTP/2 200'],
  ['cmd', 'curl -sI https://paste.example'],
  ['deny', 'curl: (6) Could not resolve host: paste.example'],
  ['cmd', `${SITE.name} grant t_7f3a api.example.com --for 10m`, 'outside, as the owner'],
  ['out', 'granted until 12:10:03'],
];

export default function Home() {
  const recorded = recordedCheckpoints();

  return (
    <>
      <Nav />
      <main id="main">
        <section className="hero">
          <div className="hero-bg" aria-hidden="true" />
          <div className="container hero-inner">
            <Link href="/docs/status/" className="pill">
              <span className="pill-dot" aria-hidden="true" />
              Proof of concept · macOS and Linux
              <span className="pill-arrow" aria-hidden="true">→</span>
            </Link>
            <h1>
              Network permissions <br className="br" />
              for apps and tasks.
            </h1>
            <p className="lede">
              A native, headless policy that attaches before a task starts. Every child process inherits it. A process
              inside can&apos;t grant itself more access.
            </p>
            <CopyCommand command={SITE.command} />
            <div className="actions">
              <Link className="btn btn-primary" href="/docs/">Read the docs</Link>
              <a className="btn btn-secondary" href={SITE.repo}>GitHub</a>
            </div>
          </div>
        </section>

        <section className="container">
          <div className="frame">
            <span className="corner corner-tl" aria-hidden="true" />
            <span className="corner corner-tr" aria-hidden="true" />
            <span className="corner corner-bl" aria-hidden="true" />
            <span className="corner corner-br" aria-hidden="true" />
            <Scene />
          </div>
          <p className="caption">Illustration with simulated traffic.</p>
        </section>

        <section className="container section">
          <h2 className="h2">Three nouns.</h2>
          <p className="sub">The same model covers a command an agent runs and an app already on the machine.</p>
          <div className="cols">
            {NOUNS.map(([k, v], i) => (
              <div className="col" key={k}>
                <p className="mono faint">0{i + 1}</p>
                <h3>{k}</h3>
                <p>{v}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="container section">
          <figure className="terminal">
            <figcaption>
              <span className="dots" aria-hidden="true"><i /><i /><i /></span>
              <span className="faint">Illustrative session · CLI not frozen</span>
            </figcaption>
            <pre>
              {SESSION.map(([kind, text, note], i) => (
                <span className={`line line-${kind}`} key={i}>
                  {kind === 'cmd' ? <span className="ps1">$ </span> : null}
                  {text}
                  {note ? <span className="comment">  # {note}</span> : null}
                  {'\n'}
                </span>
              ))}
            </pre>
          </figure>
        </section>

        <section className="container section">
          <h2 className="h2">Old Unix rules, applied to the network.</h2>
          <div className="grid4">
            {PRINCIPLES.map(([k, v]) => (
              <div className="cell" key={k}>
                <h3>{k}</h3>
                <p>{v}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="container section">
          <div className="status-head">
            <h2 className="h2">Status.</h2>
            <Link className="link" href="/docs/status/">
              {recorded.size} of {CHECKPOINTS.length} checkpoints recorded →
            </Link>
          </div>
          <div className="status">
            <div className="status-row status-labels" aria-hidden="true">
              <span />
              <span>Apps</span>
              <span>Tasks</span>
            </div>
            {MATRIX.map((row) => (
              <div className="status-row" key={row.os}>
                <span className="status-os">{row.os}</span>
                {['apps', 'tasks'].map((k) => (
                  <span className="status-cell" key={k}>
                    <span className="status-kind">{k === 'apps' ? 'Apps' : 'Tasks'}</span>
                    <span className={`state state-${row[k].state}`}>
                      <span className="state-dot" aria-hidden="true" />
                      {STATE_LABEL[row[k].state]}
                    </span>
                  </span>
                ))}
              </div>
            ))}
          </div>
        </section>
      </main>
      <Footer />
    </>
  );
}
