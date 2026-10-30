'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

export default function DocsSidebar({ groups }) {
  const pathname = usePathname() || '';
  const norm = (p) => (p.endsWith('/') ? p : `${p}/`);
  const current = norm(pathname);

  return (
    <nav className="sidebar" aria-label="Documentation">
      {groups.map((g) => (
        <div className="sidebar-group" key={g.name}>
          <p className="sidebar-title">{g.name}</p>
          <ul>
            {g.pages.map((p) => {
              const href = p.slug ? `/docs/${p.slug}/` : '/docs/';
              const active = current === href;
              return (
                <li key={href}>
                  <Link href={href} className={active ? 'active' : undefined} aria-current={active ? 'page' : undefined}>
                    {p.title}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}
