import Link from 'next/link';
import { SITE } from '../content/site';
import { Logo, Wordmark } from './Icons';
import NavLinks from './NavLinks';

export { Logo };

const FOOTER = [
  [
    'Docs',
    [
      ['Introduction', '/docs/'],
      ['How it works', '/docs/how-it-works/'],
      ['Configuration', '/docs/configuration/'],
      ['CLI', '/docs/cli/'],
    ],
  ],
  [
    'Project',
    [
      ['Roadmap', '/docs/roadmap/'],
      ['blackice', 'https://github.com/ValentinTorassa/blackice'],
    ],
  ],
];

export function Nav({ wide = false }) {
  return (
    <header className="nav">
      <a className="skip" href="#main">
        Skip to content
      </a>
      <div className={`container nav-inner${wide ? ' container-wide' : ''}`}>
        <Link className="brand" href="/" aria-label={`${SITE.name} home`}>
          <Logo size={22} />
          <Wordmark />
          <span className="brand-tag">planning</span>
        </Link>
        <div className="nav-right">
          <NavLinks repo={SITE.repo} />
        </div>
      </div>
    </header>
  );
}

export function Footer({ wide = false }) {
  return (
    <footer className="footer">
      <div className={`container footer-grid${wide ? ' container-wide' : ''}`}>
        <div className="footer-brand">
          <Link className="brand" href="/" aria-label={`${SITE.name} home`}>
            <Logo size={20} />
            <Wordmark />
          </Link>
          <p className="faint">
            In planning, by <a href={SITE.authorUrl}>{SITE.author}</a>.
          </p>
        </div>
        {FOOTER.map(([title, links]) => (
          <div className="footer-col" key={title}>
            <p className="footer-title">{title}</p>
            <ul>
              {links.map(([label, href]) => (
                <li key={href}>
                  <Link href={href}>{label}</Link>
                </li>
              ))}
            </ul>
          </div>
        ))}
        <div className="footer-col">
          <p className="footer-title">Source</p>
          <ul>
            <li>
              <a href={SITE.repo}>GitHub</a>
            </li>
            <li>
              <a href={`${SITE.repo}/blob/main/LICENSE`}>Apache-2.0</a>
            </li>
          </ul>
        </div>
      </div>
      <div className={`container${wide ? ' container-wide' : ''}`}>
        <p className="footer-note">Not affiliated with or endorsed by Apple, Vercel or Proton. Product names belong to their owners.</p>
      </div>
      <div className="footer-mark" aria-hidden="true">
        <Wordmark />
      </div>
    </footer>
  );
}
