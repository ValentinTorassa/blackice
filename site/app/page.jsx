import fs from 'node:fs';
import path from 'node:path';
import Link from 'next/link';
import { Nav, Footer } from '../components/Chrome';
import Scene from '../components/Scene';
import CopyCommand from '../components/CopyCommand';
import Spotlight from '../components/Spotlight';
import TypedTerminal from '../components/TypedTerminal';
import Layers from '../components/Layers';
import CubeMark from '../components/CubeMark';
import StatusCards from '../components/StatusCards';
import Corners from '../components/Corners';
import DemoVideo from '../components/DemoVideo';
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
import { CHECKPOINTS } from '../content/status';
import { recordedCheckpoints } from '../lib/evidence';

// The demo video is not in the repository. A deployment copies it into site/public/demo/ before the build; without
// it, the demo section is left out.
const DEMO = [
  { lang: 'en', label: 'English', src: '/demo/blackice-demo-en.mp4' },
  { lang: 'es', label: 'Español', src: '/demo/blackice-demo-es.mp4' },
].filter((s) => fs.existsSync(path.join(process.cwd(), 'public', s.src)));
const DEMO_POSTER = fs.existsSync(path.join(process.cwd(), 'public', 'demo', 'poster.jpg')) ? '/demo/poster.jpg' : null;

const NOUNS = [
  {
    name: 'Scope',
    Icon: IconNested,
    Art: IsoScope,
    text: 'What a policy applies to: one command and everything it starts, an app on the machine, or the whole host.',
  },
  {
    name: 'Policy',
    Icon: IconPolicy,
    Art: IsoPolicy,
    text: 'A JSON file. Everything is denied unless it allows it by name, subnet or port, and every address a name resolves to is checked too.',
  },
  {
    name: 'Receipt',
    Icon: IconReceipt,
    Art: IsoReceipt,
    text: 'One JSON line per decision: which scope, which version of the policy, where it was enforced, and why.',
  },
];

const PRINCIPLES = [
  { name: 'Set before exec', Icon: IconArrowInto, text: 'Like chroot, the policy is in place before the command starts, so even its first connection is checked.' },
  { name: 'Only gets stricter', Icon: IconNarrow, text: 'Anything inside can tighten a scope. Only the owner, from outside, can widen it, and only for a set time.' },
  { name: 'Goes in front of a command', Icon: IconWrap, text: 'Like nice or timeout. fx runs inside it with no changes.' },
  { name: 'Plain text receipts', Icon: IconLines, text: 'One JSON line per decision, so tail, grep and jq work on them.' },
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
              v0 · macOS and Linux
              <IconArrowRight size={13} className="pill-arrow" />
            </Link>
            <h1>
              Network permissions <br className="br" />
              for apps and tasks.
            </h1>
            <p className="lede">
              blackice decides which hosts a command can reach, along with every process it starts. The rules are in
              place before the command runs, and nothing inside can loosen them.
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

        {DEMO.length ? (
          <section className="container demo-section" id="demo" aria-labelledby="demo-title">
            <p className="eyebrow">Demo</p>
            <h2 className="h2" id="demo-title">
              fx, with blackice in front of every shell command.
            </h2>
            <DemoVideo sources={DEMO} poster={DEMO_POSTER} />
            <p className="caption">v0. Labels on screen mark what is scripted and what is not verified.</p>
          </section>
        ) : null}

        <section className="container">
          <div className="frame">
            <div className="frame-bar">
              <span className="frame-title">
                <Logo size={13} />
                scope graph
              </span>
              <span className="legend" aria-hidden="true">
                <span className="legend-scope">
                  <i className="lg lg-task" />
                  task scope
                </span>
                <span className="legend-scope">
                  <i className="lg lg-app" />
                  app scope
                </span>
                <span>
                  <i className="lg lg-allow" />
                  allowed
                </span>
                <span>
                  <i className="lg lg-deny" />
                  denied
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
          <h2 className="h2">Scopes, policies and receipts</h2>
          <p className="sub">The same three pieces cover a command an agent runs and an app already on the machine.</p>
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
              <h2 className="h2">What a connection goes through</h2>
            </div>
          </div>
          <p className="sub">
            Each connection passes these layers in order and stops at the first one that refuses it. Every decision
            leaves a receipt. The status section below shows which parts have recorded runs.
          </p>
          <Layers />
        </section>

        <section className="container section">
          <p className="eyebrow">Session</p>
          <h2 className="h2">A shell inside a scope</h2>
          <p className="sub">
            Put blackice in front of a shell, a test run or fx. Everything started inside stays in the scope. Only the
            owner, from another terminal, can allow more, and that access expires on its own.
          </p>
          <TypedTerminal lines={SESSION} title="~/project" badge="Example · the CLI may change" />
        </section>

        <section className="container section">
          <p className="eyebrow">Principles</p>
          <h2 className="h2">Built like a Unix tool</h2>
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
              <h2 className="h2">What works today</h2>
            </div>
            <Link className="link" href="/docs/status/">
              Status page
              <IconArrowRight size={14} />
            </Link>
          </div>
          <p className="sub">A part is marked Verified only when a recorded run in the repository backs it.</p>
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
          <StatusCards />
        </section>

        <section className="container section">
          <div className="cta">
            <CubeMark />
            <h2 className="h2">Read the code and the evidence</h2>
            <p className="sub">
              The design, its limits and every recorded run are in the repository. New evidence is added as each run
              is recorded.
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
