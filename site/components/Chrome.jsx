import Link from 'next/link';
import { SITE } from '../content/site';

export function Logo({ size = 20 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 2.2 20.5 7.1v9.8L12 21.8 3.5 16.9V7.1z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
      <path d="M12 7.6 16.2 10v4.9L12 17.4 7.8 14.9V10z" fill="currentColor" />
    </svg>
  );
}

function GitHubIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" fill="currentColor">
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}

export function Nav() {
  return (
    <header className="nav">
      <a className="skip" href="#main">Skip to content</a>
      <div className="container nav-inner">
        <Link className="brand" href="/" aria-label={`${SITE.name} home`}>
          <Logo />
          <span>{SITE.name}</span>
        </Link>
        <nav className="nav-links" aria-label="Main">
          <Link href="/docs/">Docs</Link>
          <Link href="/docs/status/">Status</Link>
          <a className="nav-gh" href={SITE.repo} aria-label="GitHub repository">
            <GitHubIcon />
          </a>
        </nav>
      </div>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="footer">
      <div className="container footer-inner">
        <div className="footer-brand">
          <Logo size={16} />
          <span>{SITE.name}</span>
          <span className="faint">Proof of concept by {SITE.author}</span>
        </div>
        <div className="footer-links">
          <Link href="/docs/">Docs</Link>
          <a href={SITE.repo}>GitHub</a>
          <a href={`${SITE.repo}/blob/main/LICENSE`}>Apache-2.0</a>
        </div>
      </div>
      <div className="container">
        <p className="footer-note">Not affiliated with or endorsed by Vercel. Product names belong to their owners.</p>
      </div>
    </footer>
  );
}
