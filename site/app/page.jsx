import Link from 'next/link';
import { Nav, Footer } from '../components/Chrome';
import Scene from '../components/Scene';
import CopyCommand from '../components/CopyCommand';
import Spotlight from '../components/Spotlight';
import TypedTerminal from '../components/TypedTerminal';
import Layers from '../components/Layers';
import CubeMark from '../components/CubeMark';
import Corners from '../components/Corners';
import { IsoScope, IsoPolicy, IsoReceipt } from '../components/Iso';
import {
  Logo,
  IconArrowInto,
  IconArrowRight,
  IconBook,
  IconCommand,
  IconGitHub,
  IconLines,
  IconNarrow,
  IconNested,
  IconPenguin,
  IconPolicy,
  IconReceipt,
  IconScale,
  IconTerminal,
  IconWrap,
} from '../components/Icons';
import { SITE } from '../content/site';
import { MATRIX, CHECKPOINTS, STATE_LABEL } from '../content/status';
import { recordedCheckpoints, cellState } from '../lib/evidence';

const NOUNS = [
  {
    name: 'Scope',
    Icon: IconNested,
    Art: IsoScope,
    text: 'Where a policy applies: a task and every process it starts, an app on the machine, or the host.',
  },
  {
    name: 'Policy',
    Icon: IconPolicy,
    Art: IsoPolicy,
    text: 'Deny by default, with allow lists for names, subnets and ports. Every resolved address is checked again.',
  },
  {
    name: 'Receipt',
    Icon: IconReceipt,
    Art: IsoReceipt,
    text: 'One flat JSON line per decision: the scope, the policy and its generation, where it was enforced, and why.',
  },
];

const PRINCIPLES = [
  { name: 'Born inside', Icon: IconArrowInto, text: 'The policy attaches before exec, like chroot. The first connection already runs inside it.' },
  { name: 'Only narrows', Icon: IconNarrow, text: 'Anything can tighten a scope. Widening comes from the owner, outside the task, for a set time.' },
  { name: 'Wraps any command', Icon: IconWrap, text: 'Goes in front of a command, like nice or timeout. Wrapping fx needs no changes to it.' },
  { name: 'Plain text out', Icon: IconLines, text: 'Receipts are JSON lines, so tail, grep and jq just work.' },
];

const SESSION = [
  ['cmd', `${SITE.name} run --policy policy.json -- sh`],
  ['out', 'scope s-7f3a91c2 armed  ·  policy cae35a3beb20  ·  gen 1'],
  ['cmd', "curl -so /dev/null -w '%{http_code}\\n' https://registry.npmjs.org", 'inside the scope'],
  ['ok', '200'],
  ['cmd', 'curl -sS https://paste.example'],
  ['deny', 'curl: (56) CONNECT tunnel failed, response 403'],
  ['cmd', `${SITE.name} grant s-7f3a91c2 api.example.com --for 10m`, 'another terminal, as the owner'],
  ['out', 'granted until 12:10:03'],
];

const OS_ICON = { macOS: IconCommand, Linux: IconPenguin };

function StatusDot({ state }) {
  return (
    <span className={`state state-${state}`}>
      <span className="state-dot" aria-hidden="true" />
      {STATE_LABEL[state]}
    </span>
  );
}

export default function Home() {
  const recorded = recordedCheckpoints();

  return (
    <>
      <Nav />
      <main id="main">
        <section className="hero">
          <div className="hero-bg" aria-hidden="true" />
          <div className="hero-glow" aria-hidden="true" />
          <div className="container hero-inner">
            <Link href="/docs/status/" className="pill">
              <span className="pill-dot" aria-hidden="true" />
              Proof of concept · macOS and Linux
              <IconArrowRight size={13} className="pill-arrow" />
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
              <Link className="btn btn-primary" href="/docs/">
                <IconBook size={16} />
                Read the docs
              </Link>
              <a className="btn btn-secondary" href={SITE.repo}>
                <IconGitHub size={16} />
                GitHub
              </a>
            </div>
            <ul className="chips" aria-label="Targets">
              <li>
                <IconCommand size={14} />
                macOS
              </li>
              <li>
                <IconPenguin size={14} />
                Linux
              </li>
              <li>
                <IconTerminal size={14} />
                Headless
              </li>
              <li>
                <IconScale size={14} />
                Apache-2.0
              </li>
            </ul>
          </div>
        </section>

        <section className="container">
          <div className="frame">
            <div className="frame-bar">
              <span className="frame-title">
                <Logo size={13} />
                scope graph
              </span>
              <span className="legend" aria-hidden="true">
                <span>
                  <i className="lg lg-allow" />
                  allowed
                </span>
                <span>
                  <i className="lg lg-deny" />
                  denied
                </span>
                <span className="legend-scope">
                  <i className="lg lg-scope" />
                  scope
                </span>
              </span>
            </div>
            <Scene />
            <Corners />
          </div>
          <p className="caption">Illustration with simulated traffic.</p>
        </section>

        <section className="container section">
          <p className="eyebrow">Model</p>
          <h2 className="h2">Three nouns.</h2>
          <p className="sub">The same model covers a command an agent runs and an app already on the machine.</p>
          <Spotlight className="nouns" tilt>
            {NOUNS.map(({ name, Icon, Art, text }, i) => (
              <article className="noun spot" key={name}>
                <div className="noun-art">
                  <Art />
                </div>
                <div className="noun-body">
                  <p className="noun-num">
                    <Icon size={14} />
                    0{i + 1}
                  </p>
                  <h3>{name}</h3>
                  <p>{text}</p>
                </div>
              </article>
            ))}
          </Spotlight>
        </section>

        <section className="container section">
          <div className="head-row">
            <div>
              <p className="eyebrow">Design</p>
              <h2 className="h2">Where a connection is decided.</h2>
            </div>
            <span className="badge">Proposed for v0 · not verified</span>
          </div>
          <p className="sub">
            Every connection passes the same layers. The first one that refuses it is where it stops, and the decision
            leaves a receipt.
          </p>
          <Layers />
        </section>

        <section className="container section">
          <p className="eyebrow">Session</p>
          <h2 className="h2">One command in front of anything.</h2>
          <p className="sub">
            A shell, a test run or fx. Everything started inside stays in the scope. Wider access comes from outside,
            from the owner, and ends on its own.
          </p>
          <TypedTerminal lines={SESSION} title="~/project" badge="Illustrative · CLI not frozen" />
        </section>

        <section className="container section">
          <p className="eyebrow">Principles</p>
          <h2 className="h2">Old Unix rules, applied to the network.</h2>
          <Spotlight className="grid4">
            {PRINCIPLES.map(({ name, Icon, text }) => (
              <div className="cell spot" key={name}>
                <span className="cell-icon">
                  <Icon size={18} />
                </span>
                <h3>{name}</h3>
                <p>{text}</p>
              </div>
            ))}
            <Corners />
          </Spotlight>
        </section>

        <section className="container section">
          <div className="head-row">
            <div>
              <p className="eyebrow">Status</p>
              <h2 className="h2">Nothing counts as working without a recorded run.</h2>
            </div>
            <Link className="link" href="/docs/status/">
              Status page
              <IconArrowRight size={14} />
            </Link>
          </div>
          <div className="progress">
            <p className="progress-top">
              <span className="progress-count">
                {recorded.size}
                <span>/{CHECKPOINTS.length}</span>
              </span>
              <span className="faint">checkpoints with recorded evidence</span>
            </p>
            <ol className="segments">
              {CHECKPOINTS.map(([id, name]) => {
                const on = recorded.has(id);
                return (
                  <li key={id} className={on ? 'on' : undefined} title={`${id} · ${name} · ${on ? 'recorded' : 'not run'}`}>
                    <span className="seg" />
                    <span className="seg-id">{id.slice(3)}</span>
                    <span className="sr-only">
                      {id} {name}: {on ? 'recorded' : 'not run'}
                    </span>
                  </li>
                );
              })}
            </ol>
          </div>
          <div className="os-cards">
            {MATRIX.map((row) => {
              const Icon = OS_ICON[row.os] || IconTerminal;
              return (
                <article className="os-card" key={row.os}>
                  <header>
                    <span className="os-icon">
                      <Icon size={18} />
                    </span>
                    <h3>{row.os}</h3>
                  </header>
                  {[
                    ['apps', 'Apps on the machine'],
                    ['tasks', 'Tasks an agent runs'],
                  ].map(([k, label]) => (
                    <div className="os-row" key={k}>
                      <div className="os-row-head">
                        <span>{label}</span>
                        <StatusDot state={cellState(row[k])} />
                      </div>
                      <p>{row[k].how}</p>
                    </div>
                  ))}
                </article>
              );
            })}
          </div>
        </section>

        <section className="container section">
          <div className="cta">
            <CubeMark />
            <h2 className="h2">Follow the proof.</h2>
            <p className="sub">
              The design, its limits and every checkpoint are public. Evidence lands in the repository as each run is
              recorded.
            </p>
            <div className="actions">
              <Link className="btn btn-primary" href="/docs/">
                <IconBook size={16} />
                Read the docs
              </Link>
              <a className="btn btn-secondary" href={SITE.repo}>
                <IconGitHub size={16} />
                View on GitHub
              </a>
            </div>
            <Corners />
          </div>
        </section>
      </main>
      <Footer />
    </>
  );
}
