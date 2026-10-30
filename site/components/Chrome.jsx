import Link from 'next/link';
import { SITE } from '../content/site';
import { Logo, Wordmark, IconGitHub } from './Icons';

export { Logo };

const FOOTER = [
  [
    'Docs',
    [
      ['Introduction', '/docs/'],
      ['Scopes', '/docs/scopes/'],
      ['Policies', '/docs/policies/'],
      ['Receipts', '/docs/receipts/'],
    ],
  ],
  [
    'Project',
    [
      ['Status', '/docs/status/'],
      ['Platforms', '/docs/platforms/'],
      ['fx', '/docs/fx/'],
      ['Limits', '/docs/limits/'],
    ],
  ],
];

export function Nav() {
  return (
    <header className="nav">
      <a className="skip" href="#main">
        Skip to content
      </a>
      <div className="container nav-inner">
        <Link className="brand" href="/" aria-label={`${SITE.name} home`}>
          <Logo size={22} />
          <Wordmark />
          <span className="brand-tag">PoC</span>
        </Link>
        <nav className="nav-links" aria-label="Main">
          <Link href="/docs/">Docs</Link>
          <Link href="/docs/status/">Status</Link>
          <a className="nav-gh" href={SITE.repo} aria-label="GitHub repository">
            <IconGitHub size={16} />
          </a>
        </nav>
      </div>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="footer">
      <div className="container footer-grid">
        <div className="footer-brand">
          <Link className="brand" href="/" aria-label={`${SITE.name} home`}>
            <Logo size={20} />
            <Wordmark />
          </Link>
          <p className="faint">Proof of concept by {SITE.author}.</p>
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
            <li>
              <a href={`${SITE.repo}/blob/main/SECURITY.md`}>Security</a>
            </li>
          </ul>
        </div>
      </div>
      <div className="container">
        <p className="footer-note">Not affiliated with or endorsed by Vercel. Product names belong to their owners.</p>
      </div>
      <div className="footer-mark" aria-hidden="true">
        <Wordmark />
      </div>
    </footer>
  );
}
