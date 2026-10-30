'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { IconGitHub } from './Icons';

export default function NavLinks({ repo }) {
  const path = usePathname() || '/';
  const status = path.startsWith('/docs/status');
  const docs = path.startsWith('/docs') && !status;

  return (
    <nav className="nav-links" aria-label="Main">
      <Link href="/docs/" className={docs ? 'is-active' : undefined}>
        Docs
      </Link>
      <Link href="/docs/status/" className={status ? 'is-active' : undefined}>
        Status
      </Link>
      <a className="nav-gh" href={repo} aria-label="GitHub repository">
        <IconGitHub size={16} />
      </a>
    </nav>
  );
}
