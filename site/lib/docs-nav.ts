export type DocsNavItem = {
  title: string
  href: string
  description: string
}

export type DocsNavSection = {
  title: string
  items: DocsNavItem[]
}

/* `title` and `description` are canonical for each page: the sidebar,
   pagination, llms.txt, and the markdown twins all read them from here. */
export const docsNav: DocsNavSection[] = [
  {
    title: 'Overview',
    items: [
      {
        title: 'Introduction',
        href: '/docs',
        description: 'netshield is a headless application firewall for macOS, operated through a CLI. A connection that no rule covers can wait for you, or for an agent behind a hook, to approve or deny it.',
      },
      {
        title: 'How it works',
        href: '/docs/how-it-works',
        description: 'The planned parts of netshield, and what happens to one connection in ask mode.',
      },
    ],
  },
  {
    title: 'Reference',
    items: [
      {
        title: 'Configuration',
        href: '/docs/configuration',
        description: 'netshield.toml and the event a hook receives. A proposal, not a stable format.',
      },
      {
        title: 'CLI',
        href: '/docs/cli',
        description: 'The planned commands.',
      },
    ],
  },
]

export const docsPages: DocsNavItem[] = docsNav.flatMap((section) => section.items)

export function getDocsPage(href: string): DocsNavItem | undefined {
  return docsPages.find((page) => page.href === href)
}

export function getAdjacentDocs(pathname: string) {
  const normalized = pathname.length > 1 ? pathname.replace(/\/$/, '') : pathname
  const index = docsPages.findIndex((page) => page.href === normalized)
  if (index === -1) return { previous: undefined, next: undefined }
  return { previous: docsPages[index - 1], next: docsPages[index + 1] }
}
