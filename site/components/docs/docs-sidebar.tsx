import { docsNav } from '@/lib/docs-nav'
import { NavLink } from './nav-link'

/* Desktop: a sticky column of sections. Below 900px the sections collapse
   into one wrapped row of links above the article. */
export function DocsSidebar() {
  return (
    <aside className="docs-sidebar-scroll min-w-0 min-[900px]:sticky min-[900px]:top-8 min-[900px]:max-h-[calc(100svh-4rem)] min-[900px]:self-start min-[900px]:overflow-y-auto">
      <nav
        aria-label="Documentation navigation"
        className="flex flex-wrap gap-x-5 border-b border-border pb-5 min-[900px]:block min-[900px]:border-0 min-[900px]:pb-0"
      >
        {docsNav.map((section) => (
          <div key={section.title} className="contents min-[900px]:mb-8 min-[900px]:block min-[900px]:last:mb-0">
            <p className="mb-2 hidden font-mono text-xs text-faint min-[900px]:block">{section.title}</p>
            {section.items.map((item) => (
              <NavLink key={item.href} href={item.href} title={item.title} />
            ))}
          </div>
        ))}
      </nav>
    </aside>
  )
}
