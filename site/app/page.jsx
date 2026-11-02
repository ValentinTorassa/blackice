import Link from 'next/link';
import { Nav, Footer } from '../components/Chrome';
import { FigAsk } from '../components/HowItWorks';
import { IconArrowRight, IconBook, IconCommand, IconGitHub, IconScale, IconTerminal } from '../components/Icons';
import { CONFIG_EXAMPLE } from '../content/docs';
import { SITE, STATUS } from '../content/site';

const MODES = [
  ['accept-all', 'Accept all', 'Every connection goes through. Events are still logged.'],
  ['ask', 'Ask', 'A connection that no rule covers waits while a hook asks an agent to approve or deny it.'],
  ['block-all', 'Block all', 'Only what a rule in netshield.toml allows goes through.'],
];

export default function Home() {
  return (
    <>
      <Nav />
      <main id="main">
        <section className="hero">
          <div className="hero-bg" aria-hidden="true" />
          <div className="hero-glow" aria-hidden="true" />
          <div className="container hero-inner">
            <Link href="/docs/roadmap/" className="pill">
              <span className="pill-dot" aria-hidden="true" />
              Planning · Roadmap
              <IconArrowRight size={13} className="pill-arrow" />
            </Link>
            <h1>
              Network approvals for macOS, <br className="br" />
              decided by an agent.
            </h1>
            <p className="lede">
              {SITE.name} is a network extension and a CLI, with no other UI. In ask mode, a new connection that no
              rule covers waits while a hook asks an agent such as fx to approve or deny it.
            </p>
            <p className="hero-status">{STATUS} There is nothing to install yet.</p>
            <div className="actions">
              <Link className="btn btn-primary" href="/docs/">
                <IconBook size={16} />
                Read the design
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
                <IconTerminal size={14} />
                CLI only
              </li>
              <li>
                <IconScale size={14} />
                Apache-2.0
              </li>
            </ul>
          </div>
        </section>

        <section className="container section" aria-labelledby="modes-title">
          <p className="eyebrow">Modes</p>
          <h2 className="h2" id="modes-title">
            Three modes
          </h2>
          <p className="sub">
            <code>netshield mode</code> switches between them while netshield runs. Allow rules in{' '}
            <code>netshield.toml</code> apply in ask and block-all.
          </p>
          <div className="modes">
            {MODES.map(([cmd, name, text]) => (
              <div className="mode" key={cmd}>
                <p className="mode-name">{name}</p>
                <code className="mode-cmd">netshield mode {cmd}</code>
                <p className="mode-text">{text}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="container section" aria-labelledby="ask-title">
          <p className="eyebrow">Ask mode</p>
          <h2 className="h2" id="ask-title">
            The agent answers on the command line
          </h2>
          <p className="sub">
            The hook gets the event as JSON, with a one-time token. The agent runs{' '}
            <code>netshield approve</code> or <code>netshield deny</code>, and the paused connection continues or is
            dropped.
          </p>
          <FigAsk />
          <figure className="code">
            <figcaption>
              <span className="code-title">netshield.toml</span>
              <span className="code-meta">
                <span className="code-label">Proposal</span>
              </span>
            </figcaption>
            <pre>{CONFIG_EXAMPLE}</pre>
          </figure>
        </section>

        <section className="container section about" aria-labelledby="why-title">
          <h2 className="h2" id="why-title">
            Who&apos;s building it and why
          </h2>
          <p className="sub">
            We&apos;re <a href={SITE.authorUrl}>{SITE.author}</a> and <a href={SITE.coauthorUrl}>{SITE.coauthor}</a>.
          </p>
          <p className="sub">
            Agents run on developer machines all day, and we want them to decide about network access themselves, without
            anyone clicking Allow in a dialog.
          </p>
          <p className="sub">
            The code that sees every connection on a machine is a sensitive place for a dependency. We&apos;d rather own
            that code and keep it small than install a third-party firewall with that access. {SITE.name} starts from the
            macOS app filter in <a href="https://github.com/ValentinTorassa/blackice">blackice</a>.
          </p>
        </section>
      </main>
      <Footer />
    </>
  );
}
