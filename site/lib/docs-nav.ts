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
        description: 'What blackice is, its three modes, how ask mode decides a connection, and its limits.',
      },
      {
        title: 'Install',
        href: '/docs/install',
        description: 'Install blackice, start it, answer what waits, let an agent answer, upgrade and uninstall.',
      },
    ],
  },
  {
    title: 'Reference',
    items: [
      {
        title: 'Configuration',
        href: '/docs/configuration',
        description: 'blackice.toml, and the event a hook gets and how it answers.',
      },
      {
        title: 'CLI',
        href: '/docs/cli',
        description: 'The commands.',
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
