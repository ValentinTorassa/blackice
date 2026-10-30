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
  IconArrowRight,
  IconBook,
  IconCommand,
  IconGitHub,
  IconNested,
  IconPenguin,
  IconPolicy,
  IconReceipt,
  IconScale,
  IconTerminal,
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
    text: 'One JSON line per decision: the scope, the policy and its generation, where it was enforced, and why. tail, grep and jq work on them.',
  },
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
              v0 · Status
              <IconArrowRight size={13} className="pill-arrow" />
            </Link>
            <h1>
              Network permissions <br className="br" />
              for apps and tasks.
            </h1>
            <p className="lede">
              Network rules for each app and each task, decided by a policy file. It runs headless, so nobody has to
              answer a prompt.
            </p>
            <p className="hero-status">
              Task scopes work today on macOS and on Debian 13. The macOS app filter is built in its pull request and
              needs Developer ID signing to run. The Linux app filter is in design.
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
            <h2 className="h2" id="demo-title">
              Demo
            </h2>
            <DemoVideo sources={DEMO} poster={DEMO_POSTER} />
            <p className="caption">Recorded on macOS. Labels on screen mark what is not verified.</p>
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
          <h2 className="h2">How it works</h2>
          <p className="sub">Tasks and apps use the same model: a scope, a policy and receipts.</p>
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
          <h2 className="h2">Design</h2>
          <p className="sub">
            Each connection passes these layers in order. The first layer that refuses it stops it, and the decision
            writes a receipt.
          </p>
          <Layers />
        </section>

        <section className="container section">
          <h2 className="h2">Example session</h2>
          <p className="sub">
            It goes in front of a command, like nice or timeout. Everything the command starts stays in the scope. More
            access comes from the owner, outside the scope, for a set time.
          </p>
          <TypedTerminal lines={SESSION} title="~/project" badge="Illustrative · CLI not frozen" />
        </section>

        <section className="container section">
          <div className="head-row">
            <h2 className="h2">Status</h2>
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
                  <li key={id} className={on ? 'on' : undefined} title={`${id} · ${name} · ${on ? 'recorded' : 'no entry yet'}`}>
                    <span className="seg" />
                    <span className="seg-id">{id.slice(3)}</span>
                    <span className="sr-only">
                      {id} {name}: {on ? 'recorded' : 'no entry yet'}
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
            <h2 className="h2">Docs and source</h2>
            <p className="sub">The design, its limits and the evidence for each checkpoint are in the repository.</p>
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
