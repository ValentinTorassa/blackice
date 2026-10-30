'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { IconBook, IconCompass, IconCube, IconFlag } from './Icons';

const GROUP_ICONS = { Overview: IconCompass, Concepts: IconCube, Reference: IconBook, Project: IconFlag };

export default function DocsSidebar({ groups }) {
  const pathname = usePathname() || '';
  const norm = (p) => (p.endsWith('/') ? p : `${p}/`);
  const current = norm(pathname);

  return (
    <nav className="sidebar" aria-label="Documentation">
      {groups.map((g) => {
        const Icon = GROUP_ICONS[g.name];
        return (
          <div className="sidebar-group" key={g.name}>
            <p className="sidebar-title">
              {Icon ? <Icon size={14} /> : null}
              {g.name}
            </p>
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
        );
      })}
    </nav>
  );
}
