'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { IconGitHub } from './Icons';

export default function NavLinks({ repo }) {
  const path = usePathname() || '/';
  const status = path.startsWith('/docs/roadmap');
  const docs = path.startsWith('/docs') && !status;

  return (
    <nav className="nav-links" aria-label="Main">
      <Link href="/docs/" className={docs ? 'is-active' : undefined}>
        Docs
      </Link>
      <Link href="/docs/roadmap/" className={status ? 'is-active' : undefined}>
        Roadmap
      </Link>
      <a className="nav-gh" href={repo} aria-label="GitHub repository">
        <IconGitHub size={16} />
      </a>
    </nav>
  );
}
