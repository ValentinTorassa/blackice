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
  IconArrowInto,
  IconCommand,
  IconFlag,
  IconLines,
  IconNarrow,
  IconGitHub,
  IconNested,
  IconPenguin,
  IconPolicy,
  IconReceipt,
  IconScale,
  IconTerminal,
} from '../components/Icons';
import { SITE } from '../content/site';
import { DEMO, DEMO_POSTER } from '../content/demo';
import { CHECKPOINTS } from '../content/status';
import { recordedCheckpoints } from '../lib/evidence';

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
    text: 'A JSON file. Anything it doesn\'t allow by name, subnet or port is refused, and every address a name resolves to is checked too.',
  },
  {
    name: 'Receipt',
    Icon: IconReceipt,
    Art: IsoReceipt,
    text: 'One JSON line per decision: which scope, which version of the policy, where it was enforced, and why. tail, grep and jq work on them.',
  },
];

const SESSION = [
  ['cmd', `${SITE.name} run --policy policy.json -- sh`],
  ['out', 'scope s-7f3a91c2 armed  ·  policy cae35a3beb20  ·  gen 1'],
  ['cmd', "curl -so /dev/null -w '%{http_code}\\n' https://registry.npmjs.org", 'inside the scope'],
  ['ok', '200'],
  ['cmd', 'curl -sS https://paste.example'],
  ['deny', 'curl: (56) CONNECT tunnel failed, response 403'],
  ['cmd', "tail -1 ~/.local/state/blackice/scopes/s-7f3a91c2/receipts.jsonl | jq -c '{verdict,reason,host}'", 'as the owner'],
  ['out', '{"verdict":"deny","reason":"no_matching_rule","host":"paste.example"}'],
  ['cmd', `${SITE.name} grant s-7f3a91c2 api.example.com --for 10m`, 'as the owner'],
  ['out', 'granted api.example.com to scope s-7f3a91c2 until 2026-10-30T12:10:03.000Z'],
];

const UNIX = [
  {
    name: 'Set before exec',
    Icon: IconArrowInto,
    text: 'Like chroot, the policy is in place before the command runs its first instruction, so even its first connection is checked.',
  },
  {
    name: 'No way up from inside',
    Icon: IconNarrow,
    text: 'Like a process after pledge(2), nothing inside a scope can get more access. Only the owner, from outside, can widen it, and only until a set time.',
  },
  {
    name: 'Fails early',
    Icon: IconFlag,
    text: "The Rule of Repair: fail noisily and as soon as possible. If the policy doesn't load, or doesn't match its pinned hash, the command never starts.",
  },
  {
    name: 'Everything is a file',
    Icon: IconLines,
    text: 'The policy is a file, and each logged decision is a line appended to another one. grep and jq work on both, and tail -f follows the receipts.',
  },
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
              blackice decides which hosts a command can reach, along with every process it starts. The rules are in
              place before the command runs, and nothing inside can loosen them.
            </p>
            <p className="hero-status">
              Task scopes work today on macOS and on Debian 13 (x86_64). The macOS app filter is built in its pull
              request and needs Developer ID signing to run. The Linux app filter is in design.
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
          <div className="head-row">
            <h2 className="h2">Design</h2>
            <span className="badge">v0 design · verified for task scopes on macOS and Debian 13 (x86_64)</span>
          </div>
          <p className="sub">
            Each connection passes these layers in order and stops at the first one that refuses it. A hostname hides
            the address behind it, so the proxy checks both: the name against the policy, then every address it
            resolves to. The proxy writes a receipt for each of its decisions.
          </p>
          <Layers />
        </section>

        <section className="container section">
          <h2 className="h2">A shell inside a scope</h2>
          <p className="sub">
            It goes in front of a command the way nice or timeout do: a shell, a test run or fx. Everything started
            inside stays in the scope. From another terminal, the owner can read the receipts and allow more, and that
            access expires on its own.
          </p>
          <TypedTerminal lines={SESSION} title="~/project" badge="Example · the CLI may change" />
        </section>

        <section className="container section">
          <h2 className="h2">Built like a Unix tool</h2>
          <Spotlight className="grid4">
            {UNIX.map(({ name, Icon, text }) => (
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
            <h2 className="h2">What works today</h2>
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
            <h2 className="h2">Read the code and the evidence</h2>
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
